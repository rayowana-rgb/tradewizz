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
    ACTION_REVIEW,
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
# A soft "quality below 60" only justifies a REDUCE when the engine score is
# also weak. A strong, high-score BUY name whose quality merely dipped after a
# hard down day should be HELD, not trimmed.
QUALITY_REDUCE_SCORE_CEILING = 75.0
# Loss threshold (%) for the EXIT "large loss, no recovery" rule.
EXIT_LOSS_THRESHOLD = -20.0
# Take-profit (let-winners-run friendly): only trim a winner to lock in gains
# once its momentum is fading. A position up at least TAKE_PROFIT_PCT whose
# engine score has slipped below TAKE_PROFIT_SCORE_CEILING is REDUCED to secure
# profit. A still-strong winner (score >= ceiling) keeps running untouched.
TAKE_PROFIT_PCT = 30.0
TAKE_PROFIT_SCORE_CEILING = 80.0
# Average-down (SUPPORT-BASED). A holding is flagged to consider adding at a
# better cost basis when its price is TESTING a technical support level (near a
# rolling low), not merely because of an arbitrary drawdown depth. This buys
# the dip where the tape actually finds a floor, and skips names in free-fall.
# A holding qualifies when its last close sits within SUPPORT_NEAR_PCT ABOVE
# either the immediate (10d low) or major (50d low) support.
SUPPORT_NEAR_PCT = 3.0
# Cap on how many support-based average-down ADDs may fire in one rebalance
# cycle. Averaging down should be SELECTIVE -- only the strongest few names
# testing support, not every loser near a floor. Excess candidates (ranked by
# engine score) are downgraded to HOLD.
AVERAGE_DOWN_MAX = 3
# If price has broken BELOW major support by more than this, support is
# considered failed -> do NOT average down (avoid catching a falling knife).
SUPPORT_BROKEN_PCT = 3.0
# A holding may average down only while its engine score stays at or above this
# floor; below it the weakness is treated as a warning, not a buy-the-dip.
AVERAGE_DOWN_SCORE_FLOOR = 50.0
# Over-diversification: holding far more names than a concentrated book can be
# managed as dilutes every winner and spreads capital too thin (a $8k book
# across 400 names is ~$20/position -- indistinguishable from an index, but
# paying per-name friction). Warn (not block) above this many held names so the
# user can consolidate toward the top-scored names. The band targets (Elite
# 20%, Strong 15%, Watch 10%, Weak 5%) simply cannot be met beyond ~20 names.
OVER_DIVERSIFICATION_COUNT = 60
# REVIEW trigger: an unscored (low-confidence) holding sitting on a loss at or
# beyond this magnitude is surfaced for a manual look instead of a silent HOLD.
REVIEW_LOSS_THRESHOLD = -10.0
# Relative-concentration REDUCE: a holding whose weight exceeds the average
# holding weight by more than 100% (i.e. more than 2x the average position) is
# flagged to trim/take-profit, independent of the absolute concentration cap.
RELATIVE_CONCENTRATION_MULTIPLE = 2.0
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


def _support_context(support: Optional[dict]) -> tuple:
    """Classify a holding's price vs its TESTED swing support.

    Returns ``(near_support: bool, broken: bool, level: float|None,
    touches: int)``.

    Keys on ``swing_support`` -- a level the tape has bounced off >=2x (see
    engine._tested_swing_support) -- NOT a rolling minimum. A falling stock
    always hugs its rolling low, so keying on that flagged almost everything;
    a tested swing low is a real floor.

    * ``near_support`` == price within SUPPORT_NEAR_PCT ABOVE the swing level
      (testing the floor from above).
    * ``broken``       == price more than SUPPORT_BROKEN_PCT BELOW the swing
      level (the floor gave way -> falling knife; do not buy).
    * ``level``        == the tested swing level (for the reason text).
    * ``touches``      == how many times the level was tested.
    """
    if not support:
        return (False, False, None, 0)
    try:
        price = float(support.get("price") or 0.0)
    except (TypeError, ValueError):
        price = 0.0
    if price <= 0:
        return (False, False, None, 0)
    lvl = support.get("swing_support")
    if lvl is None:
        return (False, False, None, 0)
    try:
        level = float(lvl)
    except (TypeError, ValueError):
        return (False, False, None, 0)
    if level <= 0:
        return (False, False, None, 0)
    try:
        touches = int(support.get("touches") or 0)
    except (TypeError, ValueError):
        touches = 0

    broken = price < level * (1.0 - SUPPORT_BROKEN_PCT / 100.0)
    upper = level * (1.0 + SUPPORT_NEAR_PCT / 100.0)
    near = (level <= price <= upper)
    return (near, broken, level, touches)


class RebalanceService:
    def __init__(
        self,
        health_service: HealthLike,
        positions_provider: PositionsProvider,
        account_provider: AccountProvider,
        score_provider: ScoreProvider,
        regime_provider: Optional[RegimeProvider] = None,
        profile: str = PROFILE_BALANCED,
        support_provider=None,
    ):
        self._health = health_service
        self._positions = positions_provider
        self._account = account_provider
        self._score = score_provider
        # Optional: symbol -> {"immediate_support", "major_support", "price"}
        # from CACHED OHLCV only (no live fetch). Drives the support-based
        # average-down trigger. When absent, average-down is simply skipped.
        self._support = support_provider
        self._regime = regime_provider
        self._profile = profile

    def _safe_match(self, symbol: str, market: Market):
        try:
            return self._score(symbol, market)
        except Exception:  # noqa: BLE001
            return None

    def _safe_support(self, symbol: str, market: Market):
        if self._support is None:
            return None
        try:
            return self._support(symbol, market)
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
        # Names with no live engine score have a neutral PLACEHOLDER quality;
        # we must not let that placeholder trigger a REDUCE.
        low_conf_by_key: Dict[tuple, bool] = {
            (q.symbol, q.market): bool(getattr(q, "low_confidence", False))
            for q in health.positions
        }

        values = {
            (p.symbol, p.market): max(0.0, p.market_value) for p in positions
        }
        invested = sum(values.values())
        # Average holding weight (% of invested value). Used for the
        # relative-concentration REDUCE (a name far above the average position).
        n_held = sum(1 for v in values.values() if v > 0)
        avg_weight = (100.0 / n_held) if n_held > 0 else 0.0
        try:
            cash = float(getattr(account, "cash", 0.0) or 0.0)
            equity = float(getattr(account, "equity", 0.0) or 0.0)
        except (TypeError, ValueError):
            cash, equity = 0.0, 0.0
        equity = equity if equity > 0 else (cash + invested)
        cash_alloc = round((cash / equity * 100.0) if equity > 0 else 0.0, 1)

        actions: List[RebalanceAction] = []
        warnings: List[str] = []

        # Regime is a per-MARKET property, not per-position. Computing it once
        # per distinct market (instead of once per position) avoids redundant
        # market scans for portfolios that hold many names in the same market.
        regime_by_market: Dict[Market, str] = {}

        for p in positions:
            key = (p.symbol, p.market)
            weight = (values[key] / invested * 100.0) if invested > 0 else 0.0
            match = self._safe_match(p.symbol, p.market)
            score = float(match.score) if match else 50.0
            signal = (match.signal if match else "HOLD") or "HOLD"
            quality = float(quality_by_key.get(key, 50.0))
            # A missing engine score also means we have no real quality read.
            low_conf = low_conf_by_key.get(key, match is None)
            if p.market not in regime_by_market:
                regime_by_market[p.market] = self._safe_regime(p.market)
            regime = regime_by_market[p.market]
            pnl_pct = _position_pnl_pct(p)
            pnl_value = _position_pnl_value(p)
            target = _target_weight(score, profile_cap)
            (near_support, support_broken, support_level,
             support_touches) = _support_context(
                self._safe_support(p.symbol, p.market)
            )

            action, reason, priority = _decide(
                score=score, signal=signal, quality=quality, weight=weight,
                regime=regime, pnl_pct=pnl_pct, target=target,
                avg_weight=avg_weight,
                low_confidence=low_conf,
                near_support=near_support,
                support_broken=support_broken,
                support_level=support_level,
                support_touches=support_touches,
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
                pnl_pct=round(pnl_pct, 1),
                pnl_value=round(pnl_value, 2),
            ))

        # CAP average-down ADDs (AVERAGE_DOWN_MAX). Averaging down must be
        # selective: keep only the top-N candidates by engine score (tie-break:
        # deeper loss first -> more cost-basis benefit) and downgrade the rest
        # to HOLD so a single dip doesn't turn a third of the book into buys.
        avg_down_idx = [
            i for i, a in enumerate(actions)
            if a.action == ACTION_ADD and "averaging down" in a.reason.lower()
        ]
        if len(avg_down_idx) > AVERAGE_DOWN_MAX:
            ranked = sorted(
                avg_down_idx,
                key=lambda i: (actions[i].score, -actions[i].pnl_pct),
                reverse=True,
            )
            for i in ranked[AVERAGE_DOWN_MAX:]:
                a = actions[i]
                actions[i] = a.model_copy(update={
                    "action": ACTION_HOLD,
                    "priority": PRIORITY_LOW,
                    "target_weight": round(a.current_weight, 1),
                    "reason": (
                        "Near tested support with thesis intact, but not among "
                        "the top average-down candidates this cycle — hold."
                    ),
                })

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
        n_held = sum(1 for v in values.values() if v > 0)
        if n_held > OVER_DIVERSIFICATION_COUNT:
            avg_dollar = (invested / n_held) if n_held > 0 else 0.0
            warnings.append(
                f"Over-diversified: {n_held} holdings (~${avg_dollar:,.0f} "
                f"each). This dilutes every winner and pays per-name friction. "
                f"Consider consolidating toward your top-scored names."
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


def _position_pnl_value(p) -> float:
    """Absolute unrealized P/L in account currency, when available."""
    try:
        return float(getattr(p, "unrealized_pnl", 0.0) or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _decide(
    *, score, signal, quality, weight, regime, pnl_pct, target,
    avg_weight=0.0, low_confidence=False,
    near_support=False, support_broken=False, support_level=None,
    support_touches=0,
):
    sig = (signal or "HOLD").upper()
    bearish = regime == REGIME_BEAR
    # A bear regime is a REASON to trim risk, but only where there is risk to
    # trim: a name already sitting AT or ABOVE its target weight. It must NOT
    # force a REDUCE on a name held far below target (you can't "reduce" a
    # 0.1% position whose target is 20%). Without this gate a bear read swept
    # the ENTIRE book into REDUCE with contradictory "reduce" labels on
    # below-target holdings. Small epsilon so rounding doesn't trip it.
    bearish_trim = bearish and weight >= max(target - 0.5, 0.0) and weight > 0
    # When there is no live engine score, BOTH `score` and `quality` are
    # neutral PLACEHOLDERS (50). Treat the score- and quality-based triggers as
    # inactive so an "unknown" name is never auto-EXITed / auto-REDUCEd on a
    # fabricated read. Only signals we DO trust still apply: a real SELL signal,
    # over-concentration, and a confirmed loss. Such a name is held with low
    # confidence until a real score is available.
    real = not low_confidence

    # EXIT (highest priority).
    score_exit = real and score < 45
    quality_exit = real and quality < 40
    loss_exit = real and pnl_pct <= EXIT_LOSS_THRESHOLD and score < 55
    if score_exit or sig == "SELL" or quality_exit or loss_exit:
        reasons = []
        if score_exit:
            reasons.append("score very weak")
        if sig == "SELL":
            reasons.append("engine signal is SELL")
        if quality_exit:
            reasons.append("quality very low")
        if loss_exit:
            reasons.append(f"loss {pnl_pct:.0f}% with no recovery signal")
        return (
            ACTION_EXIT,
            "Exit candidate: " + ", ".join(reasons) + ".",
            PRIORITY_HIGH,
        )

    # REDUCE. A "quality below 60" only counts when the engine score is also
    # soft (< QUALITY_REDUCE_SCORE_CEILING); a strong high-score name whose
    # quality merely dipped after a down day is NOT trimmed on that alone.
    score_reduce = real and score < 65
    quality_reduce = (
        real and quality < 60 and score < QUALITY_REDUCE_SCORE_CEILING
    )
    # Take-profit (Option 1): lock in gains on a big winner only once its
    # momentum is fading. Up >= TAKE_PROFIT_PCT AND score has slipped below
    # the ceiling -> trim. A still-strong winner (score >= ceiling) is left to
    # keep running, in line with the let-winners-run philosophy.
    take_profit = (
        real
        and pnl_pct >= TAKE_PROFIT_PCT
        and score < TAKE_PROFIT_SCORE_CEILING
    )
    # Relative concentration: this holding is more than 2x the average position
    # weight (i.e. > 100% above the average held name). Trim it back toward the
    # rest of the book / take some profit, regardless of the absolute cap.
    rel_concentration = (
        avg_weight > 0
        and weight > avg_weight * RELATIVE_CONCENTRATION_MULTIPLE
        and weight > CONCENTRATION_REDUCE * 0.5
    )
    if (
        weight > CONCENTRATION_REDUCE
        or rel_concentration
        or score_reduce
        or quality_reduce
        or take_profit
        or bearish_trim
    ):
        reasons = []
        if weight > CONCENTRATION_REDUCE:
            reasons.append(
                f"position concentration too high ({weight:.0f}%)"
            )
        elif rel_concentration:
            reasons.append(
                f"position {weight:.0f}% is well above the "
                f"{avg_weight:.0f}% average holding"
            )
        if score_reduce:
            reasons.append("score weakening")
        if quality_reduce:
            reasons.append("quality below 60")
        if take_profit:
            reasons.append(
                f"secure profit (+{pnl_pct:.0f}%) as momentum fades"
            )
        if bearish_trim:
            reasons.append("market regime bearish")
        priority = (
            PRIORITY_HIGH
            if (weight > CONCENTRATION_REDUCE or rel_concentration)
            else PRIORITY_MEDIUM
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

    # AVERAGE DOWN (SUPPORT-BASED). A holding whose price is TESTING a technical
    # support level -- a TESTED swing low the tape bounced off >=2x, NOT a mere
    # rolling minimum -- that the engine is NOT trying to exit/reduce and whose
    # score still holds above the floor, is a buy-the-dip candidate: adding
    # shares near a real floor lowers the cost basis. Gated so we never average
    # into a name the engine dislikes (those already fell through EXIT/REDUCE
    # above), never when support has BROKEN (falling knife), never while
    # sitting on a gain (averaging down only makes sense on a loss), and never
    # in a bear regime. NOTE: the caller additionally CAPS how many of these
    # fire per cycle (top-N by score) -- see AVERAGE_DOWN_MAX.
    average_down = (
        real
        and near_support
        and not support_broken
        and pnl_pct < 0.0
        and score >= AVERAGE_DOWN_SCORE_FLOOR
        and weight < target
        and not bearish
    )
    if average_down:
        level_txt = (
            f"tested support {support_level:.2f}"
            if support_level is not None
            else "tested support"
        )
        touch_txt = (
            f" ({support_touches}x tested)" if support_touches >= 2 else ""
        )
        return (
            ACTION_ADD,
            (
                f"Testing {level_txt}{touch_txt} with thesis intact "
                f"(score {score:.0f}, down {pnl_pct:.0f}%) — consider averaging "
                f"down to lower your cost basis."
            ),
            PRIORITY_MEDIUM,
        )

    # REVIEW. We have NO real engine score for this name (low_confidence) and it
    # is sitting on a meaningful loss. We will not fabricate an EXIT/REDUCE on
    # data we do not have, but a silent HOLD would bury a losing position the
    # user ought to look at. Surface it honestly for a manual review.
    if low_confidence and pnl_pct <= REVIEW_LOSS_THRESHOLD:
        return (
            ACTION_REVIEW,
            (
                f"No engine score for this name and it is down {pnl_pct:.0f}% — "
                f"outside the scored universe, so review it manually rather "
                f"than trust an automated call."
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
    n_review = sum(1 for a in actions if a.action == ACTION_REVIEW)
    n_hold = sum(1 for a in actions if a.action == ACTION_HOLD)
    bits = []
    if n_exit:
        bits.append(f"{n_exit} exit")
    if n_reduce:
        bits.append(f"{n_reduce} reduce")
    if n_add:
        bits.append(f"{n_add} add")
    if n_review:
        bits.append(f"{n_review} review")
    if n_hold:
        bits.append(f"{n_hold} hold")
    actions_txt = ", ".join(bits) if bits else "no actions"
    return (
        f"Portfolio score {score:.0f}, cash {cash_alloc:.0f}%. "
        f"Recommended: {actions_txt}."
    )
