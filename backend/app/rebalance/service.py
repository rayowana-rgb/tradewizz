"""Portfolio Rebalancing AI service — rule-based ADD/HOLD/REDUCE/EXIT.

Inputs (all existing, reused as-is):
  * Portfolio Health      -> health_score + per-position quality_score.
  * Engine score / signal -> via score_provider(symbol, market) (ScreenerMatch).
  * Current allocation    -> simulated positions' market_value (weights) and the
    simulated account cash (cash allocation).
  * Market regime         -> per-market regime via the Radar (bearish => REDUCE).

Rule engine (Phase 3 spec), evaluated per holding in priority order
EXIT > REDUCE > ADD > HOLD:

  EXIT     : score < 45, or signal == SELL, or quality < 40, or a large loss
             with no recovery signal.
  REDUCE   : position weight > 30%, or score < 65, or quality < 60, or bearish
             market regime.
  ADD      : score >= 85 and quality >= 80 and weight < target and regime not
             bearish.
  HOLD     : score 65-84 with no concentration issue (the default).

Target weight by score band (max single-position weight):
  * Elite     score >= 90 -> 20%
  * Strong    score 80-89 -> 15%
  * Watchlist score 70-79 -> 10%
  * Weak      score < 70   -> 5% (or reduce)

Default risk profile is Balanced (max position 20%). No LLM, no broker contact,
no accounting changes. Every report is marked simulated=true.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Protocol

from ..models import Market, ScreenerMatch
from ..portfolio_health.models import PortfolioHealth
from .models import (
    ACTION_ADD,
    ACTION_EXIT,
    ACTION_HOLD,
    ACTION_REDUCE,
    PRIORITY_HIGH,
    PRIORITY_LOW,
    PRIORITY_MEDIUM,
    PROFILE_AGGRESSIVE,
    PROFILE_BALANCED,
    PROFILE_CONSERVATIVE,
    RebalanceAction,
    RebalanceResponse,
)

# Max single-position weight per risk profile (% of market-invested value).
PROFILE_MAX_WEIGHT = {
    PROFILE_CONSERVATIVE: 15.0,
    PROFILE_BALANCED: 20.0,
    PROFILE_AGGRESSIVE: 30.0,
}

# Score-band target weights (max for the band).
TARGET_ELITE = 20.0     # score >= 90
TARGET_STRONG = 15.0    # 80-89
TARGET_WATCH = 10.0     # 70-79
TARGET_WEAK = 5.0       # < 70

# REDUCE trigger: a single name above this share of invested value.
CONCENTRATION_REDUCE = 30.0
# Loss threshold (%) for the EXIT "large loss, no recovery" rule.
EXIT_LOSS_THRESHOLD = -20.0
REGIME_BEAR = "BEAR"


class HealthLike(Protocol):
    def health(self, user_id: int) -> PortfolioHealth: ...


ScoreProvider = Callable[[str, Market], Optional[ScreenerMatch]]
PositionsProvider = Callable[[int], List]
AccountProvider = Callable[[int], object]
RegimeProvider = Callable[[Market], str]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _target_weight(score: float, profile_cap: float) -> float:
    if score >= 90:
        band = TARGET_ELITE
    elif score >= 80:
        band = TARGET_STRONG
    elif score >= 70:
        band = TARGET_WATCH
    else:
        band = TARGET_WEAK
    return min(band, profile_cap)


class RebalanceService:
    def __init__(
        self,
        health_service: HealthLike,
        positions_provider: PositionsProvider,
        account_provider: AccountProvider,
        score_provider: ScoreProvider,
        regime_provider: Optional[RegimeProvider] = None,
        profile: str = PROFILE_BALANCED,
    ):
        self._health = health_service
        self._positions = positions_provider
        self._account = account_provider
        self._score = score_provider
        self._regime = regime_provider
        self._profile = profile

    def _safe_match(self, symbol: str, market: Market):
        try:
            return self._score(symbol, market)
        except Exception:  # noqa: BLE001
            return None

    def _safe_regime(self, market: Market) -> str:
        if self._regime is None:
            return "NEUTRAL"
        try:
            return self._regime(market)
        except Exception:  # noqa: BLE001
            return "NEUTRAL"

    def rebalance(
        self, user_id: int, profile: Optional[str] = None
    ) -> RebalanceResponse:
        prof = profile or self._profile
        profile_cap = PROFILE_MAX_WEIGHT.get(prof, PROFILE_MAX_WEIGHT[PROFILE_BALANCED])

        health = self._health.health(user_id)
        positions = self._positions(user_id)
        account = self._account(user_id)
        quality_by_key: Dict[tuple, float] = {
            (q.symbol, q.market): q.quality_score for q in health.positions
        }

        values = {
            (p.symbol, p.market): max(0.0, p.market_value) for p in positions
        }
        invested = sum(values.values())
        try:
            cash = float(getattr(account, "cash", 0.0) or 0.0)
            equity = float(getattr(account, "equity", 0.0) or 0.0)
        except (TypeError, ValueError):
            cash, equity = 0.0, 0.0
        equity = equity if equity > 0 else (cash + invested)
        cash_alloc = round((cash / equity * 100.0) if equity > 0 else 0.0, 1)

        actions: List[RebalanceAction] = []
        warnings: List[str] = []

        for p in positions:
            key = (p.symbol, p.market)
            weight = (values[key] / invested * 100.0) if invested > 0 else 0.0
            match = self._safe_match(p.symbol, p.market)
            score = float(match.score) if match else 50.0
            signal = (match.signal if match else "HOLD") or "HOLD"
            quality = float(quality_by_key.get(key, 50.0))
            regime = self._safe_regime(p.market)
            pnl_pct = _position_pnl_pct(p)
            target = _target_weight(score, profile_cap)

            action, reason, priority = _decide(
                score=score, signal=signal, quality=quality, weight=weight,
                regime=regime, pnl_pct=pnl_pct, target=target,
            )
            actions.append(RebalanceAction(
                symbol=p.symbol,
                market=p.market,
                name=getattr(p, "name", "") or "",
                action=action,
                reason=reason,
                current_weight=round(weight, 1),
                target_weight=round(target, 1),
                priority=priority,
                score=round(score, 1),
                quality_score=round(quality, 1),
            ))

        # Sort HIGH first, then by how far off target (largest gaps first).
        order = {PRIORITY_HIGH: 0, PRIORITY_MEDIUM: 1, PRIORITY_LOW: 2}
        actions.sort(
            key=lambda a: (
                order.get(a.priority, 3),
                -abs(a.current_weight - a.target_weight),
            )
        )

        high = sum(1 for a in actions if a.priority == PRIORITY_HIGH)
        if cash_alloc < 5.0 and positions:
            warnings.append(
                "Cash is below 5% — limited flexibility to act on ADD signals."
            )
        if not positions:
            warnings.append(
                "No simulated holdings yet — buy a few names to rebalance."
            )

        improvement = _estimated_improvement(actions, health.health_score)
        summary = _summary(actions, health.health_score, cash_alloc)

        return RebalanceResponse(
            user_id=user_id,
            generated_at=_now_iso(),
            profile=prof,
            portfolio_score=health.health_score,
            cash_allocation=cash_alloc,
            actions=actions,
            summary=summary,
            warnings=warnings,
            high_priority_count=high,
            estimated_score_improvement=improvement,
            simulated=True,
        )


# --- pure helpers -----------------------------------------------------------
def _position_pnl_pct(p) -> float:
    """Unrealized P/L % from market_value vs cost basis, when available."""
    try:
        mv = float(getattr(p, "market_value", 0.0) or 0.0)
        pnl = float(getattr(p, "unrealized_pnl", 0.0) or 0.0)
        cost = mv - pnl
        if cost > 0:
            return pnl / cost * 100.0
    except (TypeError, ValueError, ZeroDivisionError):
        pass
    return 0.0


def _decide(*, score, signal, quality, weight, regime, pnl_pct, target):
    sig = (signal or "HOLD").upper()
    bearish = regime == REGIME_BEAR

    # EXIT (highest priority).
    if score < 45 or sig == "SELL" or quality < 40 or (
        pnl_pct <= EXIT_LOSS_THRESHOLD and score < 55
    ):
        reasons = []
        if score < 45:
            reasons.append("score very weak")
        if sig == "SELL":
            reasons.append("engine signal is SELL")
        if quality < 40:
            reasons.append("quality very low")
        if pnl_pct <= EXIT_LOSS_THRESHOLD and score < 55:
            reasons.append(f"loss {pnl_pct:.0f}% with no recovery signal")
        return (
            ACTION_EXIT,
            "Exit candidate: " + ", ".join(reasons) + ".",
            PRIORITY_HIGH,
        )

    # REDUCE.
    if weight > CONCENTRATION_REDUCE or score < 65 or quality < 60 or bearish:
        reasons = []
        if weight > CONCENTRATION_REDUCE:
            reasons.append(
                f"position concentration too high ({weight:.0f}%)"
            )
        if score < 65:
            reasons.append("score weakening")
        if quality < 60:
            reasons.append("quality below 60")
        if bearish:
            reasons.append("market regime bearish")
        priority = (
            PRIORITY_HIGH if weight > CONCENTRATION_REDUCE else PRIORITY_MEDIUM
        )
        return (
            ACTION_REDUCE,
            "Reduce: " + ", ".join(reasons) + ".",
            priority,
        )

    # ADD / INCREASE.
    if score >= 85 and quality >= 80 and weight < target and not bearish:
        return (
            ACTION_ADD,
            (
                f"Strong name (score {score:.0f}, quality {quality:.0f}) below "
                f"its {target:.0f}% target — consider increasing."
            ),
            PRIORITY_MEDIUM,
        )

    # HOLD (default; score 65-84 with no concentration issue).
    return (
        ACTION_HOLD,
        "On track — maintain current position.",
        PRIORITY_LOW,
    )


def _estimated_improvement(actions, current_score: float) -> float:
    """Rough estimate of health-score upside if HIGH actions are taken."""
    if not actions:
        return 0.0
    gain = 0.0
    for a in actions:
        if a.action == ACTION_EXIT and a.priority == PRIORITY_HIGH:
            gain += 4.0
        elif a.action == ACTION_REDUCE and a.priority == PRIORITY_HIGH:
            gain += 3.0
        elif a.action == ACTION_ADD:
            gain += 1.5
    return round(min(gain, max(0.0, 100.0 - current_score)), 1)


def _summary(actions, score: float, cash_alloc: float) -> str:
    if not actions:
        return (
            "No simulated holdings to rebalance yet. Add a few names to get "
            "personalized rebalancing guidance."
        )
    n_exit = sum(1 for a in actions if a.action == ACTION_EXIT)
    n_reduce = sum(1 for a in actions if a.action == ACTION_REDUCE)
    n_add = sum(1 for a in actions if a.action == ACTION_ADD)
    n_hold = sum(1 for a in actions if a.action == ACTION_HOLD)
    bits = []
    if n_exit:
        bits.append(f"{n_exit} exit")
    if n_reduce:
        bits.append(f"{n_reduce} reduce")
    if n_add:
        bits.append(f"{n_add} add")
    if n_hold:
        bits.append(f"{n_hold} hold")
    actions_txt = ", ".join(bits) if bits else "no actions"
    return (
        f"Portfolio score {score:.0f}, cash {cash_alloc:.0f}%. "
        f"Recommended: {actions_txt}."
    )
