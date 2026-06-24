"""Bridge that runs the EXISTING Portfolio Health + Rebalancing AI services
over LIVE Moomoo holdings.

We do not duplicate any health / rebalance logic. Instead we adapt the live
Moomoo account + positions into the lightweight shape the existing services
already expect (objects exposing ``.symbol`` / ``.market`` / ``.quantity`` /
``.market_value`` for positions, and ``.cash`` / ``.equity`` for the account),
then reuse PortfolioHealthService and RebalanceService with the SAME scoring
engine and regime provider used for the simulation.

No mock data: every number comes from the live Moomoo account/positions plus
the existing real scoring engine.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, List

from ..models import Market
from ..portfolio_health.service import PortfolioHealthService
from ..rebalance.service import RebalanceService

# Moomoo live holdings are US-listed; the scoring engine + regime are per-market.
_MOOMOO_MARKET = Market.US


@dataclass
class _PosAdapter:
    symbol: str
    market: Market
    quantity: float
    market_value: float
    unrealized_pnl: float = 0.0


@dataclass
class _AcctAdapter:
    cash: float
    equity: float


class MoomooAnalytics:
    """Owns Health + Rebalance services bound to a live-Moomoo provider."""

    def __init__(
        self,
        moomoo_service,
        score_provider: Callable,
        regime_provider: Callable,
    ):
        self._moomoo = moomoo_service
        # The providers ignore user_id: the live account is single-user (owner).
        self._health = PortfolioHealthService(
            positions_provider=self._positions,
            score_provider=score_provider,
        )
        self._rebalance = RebalanceService(
            health_service=self._health,
            positions_provider=self._positions,
            account_provider=self._account,
            score_provider=score_provider,
            regime_provider=regime_provider,
        )

    # -- adapters --------------------------------------------------------
    def _positions(self, _user_id=0) -> List[_PosAdapter]:
        out: List[_PosAdapter] = []
        for p in self._moomoo.positions():
            out.append(
                _PosAdapter(
                    symbol=p.symbol,
                    market=_MOOMOO_MARKET,
                    quantity=p.qty,
                    market_value=max(0.0, p.qty * p.last_price),
                    unrealized_pnl=float(getattr(p, "pl_val", 0.0) or 0.0),
                )
            )
        return out

    def _account(self, _user_id=0) -> _AcctAdapter:
        a = self._moomoo.account()
        return _AcctAdapter(cash=float(a.cash or 0.0),
                            equity=float(a.total_assets or 0.0))

    # -- public ----------------------------------------------------------
    def health(self):
        return self._health.health(0)

    def rebalance(self, profile=None):
        return self._rebalance.rebalance(0, profile=profile)
