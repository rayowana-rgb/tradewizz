"""AI Portfolio Manager service — rule-based advisory over the simulation.

Inputs (all existing, reused as-is):
  * Portfolio Health  -> health_score + components (diversification /
    concentration / quality).
  * Position Quality  -> per-position quality_score (drives weak/strong calls).
  * Current allocation-> simulated positions' market_value (concentration) and
    the simulated account cash (cash allocation).
  * Optional score snapshots from the Portfolio Journal -> detect a score that
    has *fallen* since purchase (e.g. "88 -> 61").

No LLM. No new scoring/indicators. No broker contact. Every report is marked
simulated=true.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Protocol

from ..models import Market
from ..portfolio_health.models import PortfolioHealth, PositionQuality
from .models import PortfolioManagerReport, Recommendation

# A single name above this share of equity is "elevated" concentration.
CONCENTRATION_WARN = 0.35       # 35% -> warning
CONCENTRATION_CRITICAL = 0.55   # 55% -> critical
# Cash below this share limits flexibility.
CASH_FLOOR = 0.05               # 5%
# Position-quality thresholds.
WEAK_QUALITY = 60.0
STRONG_QUALITY = 80.0
# A score that has dropped at least this much since purchase is flagged.
SCORE_DROP_WARN = 15.0


class HealthLike(Protocol):
    def health(self, user_id: int) -> PortfolioHealth: ...


# positions_provider(user_id) -> list of objects with .symbol/.market/
# .market_value (the simulated positions). account_provider(user_id) -> object
# with .cash and .equity. snapshot_provider(user_id) -> {(symbol, market):
# entry_score} from the Journal (optional; may be empty).
PositionsProvider = Callable[[int], List]
AccountProvider = Callable[[int], object]
SnapshotProvider = Callable[[int], Dict]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _risk_level(
    health_score: float, largest_pct: float, cash_pct: float
) -> str:
    """HIGH when health is weak or a single name dominates; else MODERATE/LOW."""
    if health_score < 55 or largest_pct >= CONCENTRATION_CRITICAL * 100:
        return "HIGH"
    if (health_score >= 80 and largest_pct < CONCENTRATION_WARN * 100
            and cash_pct >= CASH_FLOOR * 100):
        return "LOW"
    return "MODERATE"


class PortfolioManagerService:
    def __init__(
        self,
        health_service: HealthLike,
        positions_provider: PositionsProvider,
        account_provider: AccountProvider,
        snapshot_provider: Optional[SnapshotProvider] = None,
    ):
        self._health = health_service
        self._positions = positions_provider
        self._account = account_provider
        self._snapshots = snapshot_provider

    def report(self, user_id: int) -> PortfolioManagerReport:
        health = self._health.health(user_id)
        positions = self._positions(user_id)
        account = self._account(user_id)

        # Allocation math (current, from the simulation).
        values = {
            (p.symbol, p.market): max(0.0, p.market_value) for p in positions
        }
        market_total = sum(values.values())
        try:
            cash = float(getattr(account, "cash", 0.0) or 0.0)
            equity = float(getattr(account, "equity", 0.0) or 0.0)
        except (TypeError, ValueError):
            cash, equity = 0.0, 0.0
        equity = equity if equity > 0 else (cash + market_total)
        cash_pct = (cash / equity * 100.0) if equity > 0 else 0.0

        # Largest single position share.
        largest_pct = 0.0
        largest_key = None
        if market_total > 0:
            largest_key, largest_val = max(values.items(), key=lambda kv: kv[1])
            largest_pct = largest_val / market_total * 100.0

        quality_by_key = {
            (q.symbol, q.market): q for q in health.positions
        }
        snapshots = (self._snapshots(user_id) if self._snapshots else {}) or {}

        recs = self._recommendations(
            positions=positions,
            values=values,
            market_total=market_total,
            largest_key=largest_key,
            largest_pct=largest_pct,
            cash_pct=cash_pct,
            quality_by_key=quality_by_key,
            snapshots=snapshots,
        )

        return PortfolioManagerReport(
            user_id=user_id,
            generated_at=_now_iso(),
            risk_level=_risk_level(health.health_score, largest_pct, cash_pct),
            portfolio_score=health.health_score,
            concentration_score=health.components.concentration_risk,
            diversification_score=health.components.diversification,
            quality_score=health.components.quality,
            cash_pct=round(cash_pct, 1),
            largest_position_pct=round(largest_pct, 1),
            recommendations=recs,
            simulated=True,
        )

    def _recommendations(
        self,
        *,
        positions,
        values,
        market_total,
        largest_key,
        largest_pct,
        cash_pct,
        quality_by_key,
        snapshots,
    ) -> List[Recommendation]:
        recs: List[Recommendation] = []

        if not positions:
            recs.append(
                Recommendation(
                    kind="health",
                    severity="info",
                    title="No holdings yet",
                    message=(
                        "Your simulated portfolio is empty. Add a few names to "
                        "unlock concentration, quality and cash analysis."
                    ),
                )
            )
            return recs

        # --- Concentration ------------------------------------------------
        if largest_key is not None and market_total > 0:
            sym, mkt = largest_key
            if largest_pct >= CONCENTRATION_CRITICAL * 100:
                recs.append(Recommendation(
                    kind="concentration", severity="critical",
                    symbol=sym, market=mkt,
                    title="High concentration",
                    message=(
                        f"{sym} represents {largest_pct:.0f}% of portfolio "
                        "value. Portfolio concentration is elevated."
                    ),
                ))
            elif largest_pct >= CONCENTRATION_WARN * 100:
                recs.append(Recommendation(
                    kind="concentration", severity="warning",
                    symbol=sym, market=mkt,
                    title="Elevated concentration",
                    message=(
                        f"{sym} represents {largest_pct:.0f}% of portfolio "
                        "value. Consider trimming to reduce single-name risk."
                    ),
                ))

        # --- Weak / strong positions -------------------------------------
        for key, q in quality_by_key.items():
            sym, mkt = key
            entry = snapshots.get(key)
            cur = q.quality_score
            # Score has fallen materially since purchase.
            if entry is not None and (entry - cur) >= SCORE_DROP_WARN:
                recs.append(Recommendation(
                    kind="weak_position", severity="warning",
                    symbol=sym, market=mkt,
                    title="Weakening position",
                    message=(
                        f"Position {sym} score has fallen from "
                        f"{entry:.0f} to {cur:.0f}. Review holding."
                    ),
                ))
            elif cur < WEAK_QUALITY:
                recs.append(Recommendation(
                    kind="weak_position", severity="warning",
                    symbol=sym, market=mkt,
                    title="Weak position",
                    message=(
                        f"Position {sym} quality is low "
                        f"({cur:.0f}/100). Review holding."
                    ),
                ))
            elif cur >= STRONG_QUALITY:
                recs.append(Recommendation(
                    kind="strong_position", severity="info",
                    symbol=sym, market=mkt,
                    title="Strong position",
                    message=(
                        f"{sym} remains one of the highest-quality positions "
                        "in your portfolio."
                    ),
                ))

        # --- Cash allocation ---------------------------------------------
        if cash_pct < CASH_FLOOR * 100:
            recs.append(Recommendation(
                kind="cash_allocation", severity="warning",
                title="Low cash",
                message=(
                    "Cash position is below 5%. Portfolio flexibility is "
                    "limited."
                ),
            ))

        # --- Diversification ---------------------------------------------
        if len(positions) < 3:
            recs.append(Recommendation(
                kind="diversification", severity="warning",
                title="Low diversification",
                message=(
                    "Fewer than 3 holdings increases single-name risk. "
                    "Consider adding positions across sectors/markets."
                ),
            ))

        return recs
