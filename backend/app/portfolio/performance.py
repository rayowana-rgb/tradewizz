"""Portfolio performance analytics + snapshot persistence.

Derives metrics from the unified portfolio (no broker logic here) plus stored
snapshots for the equity curve and daily P/L. Realized P/L is never fabricated:
if a broker doesn't provide it, it stays 0 and a note is added.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import List, Optional

from .models import (
    AssetBreakdown,
    BrokerBreakdown,
    BrokerError,
    EquityPoint,
    PortfolioPerformance,
    PortfolioSnapshot,
    PositionPnL,
    UnifiedPortfolio,
)
from .service import PortfolioService
from .store import SnapshotStore

REALIZED_PNL_NOTE = "Realized P/L not available for this broker yet."
NO_HISTORY_NOTE = "No performance history yet."

# Map a market code to a coarse asset-class label for the breakdown.
_ASSET_LABEL = {
    "HKEX": "HKEX",
    "KOSPI": "KOSPI",
    "KOSDAQ": "KOSDAQ",
    "IDX": "IDX",
}


def _today_start_iso() -> str:
    now = datetime.now(timezone.utc)
    return now.replace(hour=0, minute=0, second=0, microsecond=0).isoformat()


class PerformanceService:
    def __init__(
        self,
        portfolio: Optional[PortfolioService] = None,
        store: Optional[SnapshotStore] = None,
        db_path: Optional[str] = None,
    ):
        self._portfolio = portfolio or PortfolioService()
        if store is not None:
            self._store = store
        else:
            from ..auth.config import AuthConfig
            from .store import SqliteSnapshotStore

            self._store = SqliteSnapshotStore(
                db_path or AuthConfig.from_env().db_path
            )

    @property
    def store(self) -> SnapshotStore:
        return self._store

    # -- snapshot --------------------------------------------------------

    def create_snapshot(self, user_id: int) -> PortfolioSnapshot:
        p = self._portfolio.for_user(user_id)
        s = p.summary
        rec = self._store.create(
            user_id=user_id,
            total_equity=s.total_equity,
            cash=s.cash,
            market_value=s.market_value,
            floating_pnl=s.floating_pnl,
            realized_pnl=s.realized_pnl,
        )
        return PortfolioSnapshot(
            id=rec.id, user_id=rec.user_id, timestamp=rec.timestamp,
            total_equity=rec.total_equity, cash=rec.cash,
            market_value=rec.market_value, floating_pnl=rec.floating_pnl,
            realized_pnl=rec.realized_pnl,
        )

    # -- performance -----------------------------------------------------

    def performance(self, user_id: int) -> PortfolioPerformance:
        p = self._portfolio.for_user(user_id)
        s = p.summary

        total_pnl = round(s.floating_pnl + s.realized_pnl, 2)

        # Daily P/L: current equity vs the latest snapshot taken before today.
        daily_pnl = 0.0
        daily_pct = 0.0
        baseline = self._store.latest_before(user_id, _today_start_iso())
        if baseline is not None:
            daily_pnl = round(s.total_equity - baseline.total_equity, 2)
            if baseline.total_equity:
                daily_pct = round(
                    daily_pnl / baseline.total_equity * 100, 2
                )

        equity_curve = [
            EquityPoint(timestamp=r.timestamp, total_equity=r.total_equity)
            for r in self._store.list_for_user(user_id)
        ]

        broker_breakdown = self._broker_breakdown(p)
        asset_breakdown = self._asset_breakdown(p)
        winners, losers = self._winners_losers(p)

        notes: List[str] = []
        if s.realized_pnl == 0.0:
            notes.append(REALIZED_PNL_NOTE)
        if not equity_curve:
            notes.append(NO_HISTORY_NOTE)

        errors = [
            BrokerError(broker=e.broker, message=e.message) for e in p.errors
        ]

        return PortfolioPerformance(
            total_equity=s.total_equity,
            cash=s.cash,
            market_value=s.market_value,
            floating_pnl=s.floating_pnl,
            realized_pnl=s.realized_pnl,
            total_pnl=total_pnl,
            daily_pnl=daily_pnl,
            daily_pnl_percent=daily_pct,
            equity_curve=equity_curve,
            broker_breakdown=broker_breakdown,
            asset_breakdown=asset_breakdown,
            top_winners=winners,
            top_losers=losers,
            notes=notes,
            errors=errors,
        )

    # -- breakdowns ------------------------------------------------------

    @staticmethod
    def _broker_breakdown(p: UnifiedPortfolio) -> List[BrokerBreakdown]:
        agg: dict = {}
        for pos in p.positions:
            b = agg.setdefault(
                pos.broker,
                {"equity": 0.0, "cash": 0.0, "market_value": 0.0,
                 "floating_pnl": 0.0},
            )
            b["market_value"] += pos.market_value
            b["floating_pnl"] += pos.unrealized_pnl
        # equity per broker isn't separable from the aggregate summary without
        # per-broker account calls; approximate equity as market_value here and
        # leave cash 0 (the summary carries the true cash/equity totals).
        out = []
        for broker, v in agg.items():
            out.append(BrokerBreakdown(
                broker=broker,
                equity=round(v["market_value"], 2),
                cash=round(v["cash"], 2),
                market_value=round(v["market_value"], 2),
                floating_pnl=round(v["floating_pnl"], 2),
            ))
        out.sort(key=lambda x: x.market_value, reverse=True)
        return out

    @staticmethod
    def _asset_breakdown(p: UnifiedPortfolio) -> List[AssetBreakdown]:
        agg: dict = {}
        for pos in p.positions:
            label = _ASSET_LABEL.get(pos.market.value, pos.market.value)
            a = agg.setdefault(label, {"mv": 0.0, "pl": 0.0})
            a["mv"] += pos.market_value
            a["pl"] += pos.unrealized_pnl
        out = [
            AssetBreakdown(asset=k, market_value=round(v["mv"], 2),
                           floating_pnl=round(v["pl"], 2))
            for k, v in agg.items()
        ]
        # Cash bucket from the summary.
        if p.summary.cash:
            out.append(AssetBreakdown(
                asset="Cash", market_value=round(p.summary.cash, 2),
                floating_pnl=0.0))
        out.sort(key=lambda x: x.market_value, reverse=True)
        return out

    @staticmethod
    def _winners_losers(p: UnifiedPortfolio):
        scored = []
        for pos in p.positions:
            cost_basis = pos.average_cost * pos.quantity
            pct = (
                round(pos.unrealized_pnl / cost_basis * 100, 2)
                if cost_basis else 0.0
            )
            scored.append(PositionPnL(
                symbol=pos.symbol, broker=pos.broker,
                unrealized_pnl=round(pos.unrealized_pnl, 2),
                unrealized_pnl_percent=pct,
            ))
        winners = sorted(
            [s for s in scored if s.unrealized_pnl > 0],
            key=lambda x: x.unrealized_pnl, reverse=True,
        )[:5]
        losers = sorted(
            [s for s in scored if s.unrealized_pnl < 0],
            key=lambda x: x.unrealized_pnl,
        )[:5]
        return winners, losers
