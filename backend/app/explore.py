"""Phase 9A: Explore intelligence layer (bot9 category bonus + conviction).

This module is *additive* on top of the existing scoring engine. It never
touches the Base Score (technical + ML + liquidity cap), the fear/greed
condition, the portfolio, or the snapshot architecture. It only computes two
independent overlays and combines them with the Base Score:

    Final Explore Score = clamp(Base Score + Category Bonus + Conviction, 0..100)

Category Bonus (Rule 3)
    Restores the bot9 ``screen_idx_stocks`` category edge as a bounded bonus.
    Weighted by category, summed, then capped at +25. ``short_candidate`` never
    adds score (and is intentionally given no positive weight).

Conviction Score (Rule 4)
    Reuses the bot9 ``analyze_screened_stocks`` confirmation concepts — CMF,
    OBV, ADX, volume confirmation, MACD confirmation, RSI quality — as an
    independent 0..20 money-flow / trend-quality gauge.

Everything here is pure: deterministic functions of the already-computed
indicator dict ``ind`` and the category list ``cats``. No I/O, no fetching.
"""

from __future__ import annotations

from typing import Dict, List, Optional

from .models import ScreenerCategory

# --------------------------------------------------------------------------- #
# Rule 3: Category Bonus                                                       #
# --------------------------------------------------------------------------- #
# Suggested weights from the spec. ``short_candidate`` is deliberately absent
# (it must NEVER increase the score). Any category without a weight contributes
# 0 (e.g. bullish/bearish approximations, scalping, swing_trade).
CATEGORY_WEIGHTS: Dict[ScreenerCategory, int] = {
    ScreenerCategory.bullish: 5,
    ScreenerCategory.pullback: 5,
    ScreenerCategory.accumulation: 8,
    ScreenerCategory.frequently_traded: 5,
    ScreenerCategory.turnaround_multibagger: 12,
    ScreenerCategory.accumulation_silent: 15,
    ScreenerCategory.ara_hunter: 10,
}

CATEGORY_BONUS_CAP = 25
# Sum of _CONVICTION_POINTS (cmf4+obv4+adx4+volume3+macd3+rsi2+trend3+breakout3).
CONVICTION_MAX = 26

# The overlay's theoretical maximum (full category bonus + full conviction).
# The Final Explore Score consumes the headroom between the Base Score and 100
# *proportionally* to how much of this maximum a name earns, so 100 is reserved
# for genuine confluence (high Base AND near-complete overlay) instead of being
# reached by almost any liquid, mildly-confirmed name. See ``explore_score``.
OVERLAY_MAX = CATEGORY_BONUS_CAP + CONVICTION_MAX  # 45


def category_bonus(cats: List[ScreenerCategory]) -> int:
    """Sum the per-category weights, capped at +25.

    ``short_candidate`` contributes nothing (no positive weight). Unknown /
    unweighted categories contribute 0. Result is always 0..25.
    """
    if not cats:
        return 0
    total = sum(CATEGORY_WEIGHTS.get(c, 0) for c in cats)
    return max(0, min(CATEGORY_BONUS_CAP, total))


# --------------------------------------------------------------------------- #
# Rule 4: Conviction Score (0..26)                                            #
# --------------------------------------------------------------------------- #
# Independent money-flow / trend-quality confirmations, each worth a slice of
# the 0..CONVICTION_MAX range. The first six are ported conceptually from bot9
# analyze_screened_stocks' buy-signal confirmation block (CMF>0, OBV rising,
# ADX>25, volume spike, MACD bullish crossover, RSI healthy band). Phase 12
# (Task B) adds two structural confirmations already computable from the
# existing indicator set -- trend structure (price above its moving averages,
# with a golden-cross bias) and breakout (price pushing its recent range) --
# so "bullish" in Explore means genuinely trending + breaking out, not just a
# green tape day. All gates are ``None``-safe: a missing indicator never fires.
_CONVICTION_POINTS = {
    "cmf": 4,        # Strong CMF: positive Chaikin money flow
    "obv": 4,        # Strong OBV: rising on-balance volume
    "adx": 4,        # Strong ADX: trend strength > 25
    "volume": 3,     # Volume confirmation (spike vs 10d avg)
    "macd": 3,       # MACD bullish confirmation
    "rsi": 2,        # RSI quality band (healthy, not overbought/oversold)
    "trend": 3,      # Trend structure: price above EMA20>EMA50, above EMA200
    "breakout": 3,   # Breakout: price at/through upper Bollinger or 20d high
}

# Human-readable one-line reason for each confirmation, used by the Explore
# card so the user can see WHY a name is bullish (Task A: transparency).
_CONVICTION_LABELS = {
    "cmf": "Money flowing in (CMF > 0)",
    "obv": "Volume accumulating (OBV rising)",
    "adx": "Strong trend (ADX > 25)",
    "volume": "Volume surge (>1.5× 10-day avg)",
    "macd": "MACD bullish crossover",
    "rsi": "RSI healthy (50–75)",
    "trend": "Uptrend structure (above key MAs)",
    "breakout": "Breaking out of range",
}


def conviction_signals(ind: dict) -> Dict[str, bool]:
    """Return which conviction confirmations fired (booleans).

    Each is independently ``None``-safe; a missing indicator simply doesn't
    fire. Mirrors the bot9 confirmation gates used in analyze_screened_stocks,
    plus the Phase-12 trend-structure and breakout confirmations.
    """
    cmf = ind.get("cmf")
    obv = ind.get("obv")
    obv_prev = ind.get("obv_prev")
    adx = ind.get("adx")
    volume = ind.get("volume")
    vol_mean_10 = ind.get("vol_mean_10")
    macd = ind.get("macd")
    macd_signal = ind.get("macd_signal")
    rsi = ind.get("rsi")
    close = ind.get("close")
    ema20 = ind.get("ema20")
    ema50 = ind.get("ema50")
    ema200 = ind.get("ema200")
    bb_upper = ind.get("bb_upper")
    high_52w = ind.get("high_52w")
    major_res = ind.get("major_resistance")

    # Trend structure: price above a rising MA stack. We require price above
    # EMA20 AND EMA20 above EMA50 (short-term uptrend) AND price above EMA200
    # when EMA200 is available (long-term uptrend / not below the 200). If
    # EMA200 is missing (young history) we fall back to the short stack alone.
    trend = (
        close is not None
        and ema20 is not None
        and ema50 is not None
        and close > ema20 > ema50
        and (ema200 is None or close > ema200)
    )

    # Breakout: price at/through the upper Bollinger band, OR within 1% of the
    # 50-day resistance / near a fresh high. Any one qualifies (None-safe).
    breakout = False
    if close is not None:
        if bb_upper is not None and close >= bb_upper:
            breakout = True
        elif major_res is not None and major_res > 0 and close >= major_res * 0.99:
            breakout = True
        elif high_52w is not None and high_52w > 0 and close >= high_52w * 0.98:
            breakout = True

    return {
        "cmf": cmf is not None and cmf > 0,
        "obv": obv is not None and obv_prev is not None and obv > obv_prev,
        "adx": adx is not None and adx > 25,
        "volume": (
            volume is not None
            and vol_mean_10 is not None
            and volume > vol_mean_10 * 1.5
        ),
        "macd": (
            macd is not None and macd_signal is not None and macd > macd_signal
        ),
        "rsi": rsi is not None and 50 < rsi < 75,
        "trend": bool(trend),
        "breakout": bool(breakout),
    }


def conviction_reasons(ind: dict) -> List[str]:
    """Human-readable reasons for the confirmations that fired (Task A).

    Ordered by point weight (strongest first) so the most meaningful signals
    lead. Deterministic; purely a read-out of ``conviction_signals``.
    """
    fired = conviction_signals(ind)
    ordered = sorted(
        (k for k, ok in fired.items() if ok),
        key=lambda k: _CONVICTION_POINTS.get(k, 0),
        reverse=True,
    )
    return [_CONVICTION_LABELS[k] for k in ordered if k in _CONVICTION_LABELS]


def confirmations_fired(ind: dict) -> int:
    """Count how many of the conviction confirmations fired (0..8)."""
    return sum(1 for ok in conviction_signals(ind).values() if ok)


def confirmations_total() -> int:
    """Total number of conviction confirmations available."""
    return len(_CONVICTION_POINTS)


def conviction_score(ind: dict) -> int:
    """0..CONVICTION_MAX conviction from the money-flow/trend confirmations."""
    fired = conviction_signals(ind)
    total = sum(_CONVICTION_POINTS[k] for k, ok in fired.items() if ok)
    return max(0, min(CONVICTION_MAX, total))


# --------------------------------------------------------------------------- #
# Rule 5: Final Explore Score                                                  #
# --------------------------------------------------------------------------- #
def explore_score(
    base_score: float, bonus: int, conviction: int
) -> float:
    """Final Explore Score with diminishing returns toward 100 (Phase 9A+).

    The overlay (category bonus + conviction) consumes the *headroom* between
    the Base Score and 100 in proportion to how much of ``OVERLAY_MAX`` the
    name earns::

        headroom = 100 - base
        final    = base + headroom * (bonus + conviction) / OVERLAY_MAX

    Properties (vs the previous additive ``base + bonus + conviction`` clamp):
      * The overlay can still only *lift* the score (final >= base), preserving
        the "bonus lifts final above base" contract.
      * 100 is reserved for genuine confluence: it requires BOTH a high Base
        Score AND a near-complete overlay. A merely-liquid, mildly-confirmed
        name no longer saturates at 100, so the top of Explore differentiates
        again instead of collapsing into a wall of 100s.
      * Monotonic in base, bonus, and conviction, so ranking order is stable.
      * Degrades cleanly: zero overlay -> final == base; full overlay on a
        base of 100 -> 100.
    """
    base = max(0.0, min(100.0, float(base_score)))
    overlay = float(bonus) + float(conviction)
    if OVERLAY_MAX <= 0 or overlay <= 0:
        return round(base, 1)
    headroom = 100.0 - base
    fraction = min(1.0, overlay / OVERLAY_MAX)
    final = base + headroom * fraction
    return round(max(0.0, min(100.0, final)), 1)


# --------------------------------------------------------------------------- #
# Rule 6: UI tags                                                             #
# --------------------------------------------------------------------------- #
_CATEGORY_TAGS = {
    ScreenerCategory.bullish: "Bullish",
    ScreenerCategory.accumulation: "Accumulation",
    ScreenerCategory.frequently_traded: "Frequently Traded",
    ScreenerCategory.accumulation_silent: "Silent Accumulation",
    ScreenerCategory.pullback: "Pullback",
    ScreenerCategory.turnaround_multibagger: "Turnaround Multibagger",
    ScreenerCategory.ara_hunter: "ARA Hunter",
}


def explore_tags(cats: List[ScreenerCategory], ind: dict) -> List[str]:
    """Human-readable tags for Explore cards (Rule 6).

    Category tags (Bullish / Accumulation / Frequently Traded / Silent
    Accumulation, ...) plus conviction tags (Strong CMF / Strong OBV /
    Strong ADX) when those confirmations fire.
    """
    tags: List[str] = []
    for c in cats or []:
        label = _CATEGORY_TAGS.get(c)
        if label and label not in tags:
            tags.append(label)
    fired = conviction_signals(ind)
    if fired.get("cmf"):
        tags.append("Strong CMF")
    if fired.get("obv"):
        tags.append("Strong OBV")
    if fired.get("adx"):
        tags.append("Strong ADX")
    if fired.get("trend"):
        tags.append("Uptrend")
    if fired.get("breakout"):
        tags.append("Breakout")
    return tags


# --------------------------------------------------------------------------- #
# Convenience: compute the whole overlay in one call                          #
# --------------------------------------------------------------------------- #
def compute_overlay(
    base_score: float,
    cats: List[ScreenerCategory],
    ind: dict,
    *,
    allow_bonus: bool = True,
    score_ceiling: Optional[float] = None,
) -> dict:
    """Compute the full Explore overlay for one match.

    ``allow_bonus=False`` (used for mock / no-data fallback rows) forces both
    the category bonus and the conviction score to 0 so a fabricated row can
    never out-rank a real one (Rule 8 #7). The Final Score then equals the
    Base Score and no tags are emitted.

    ``score_ceiling`` is the liquidity cap that already constrained the Base
    Score. The additive category bonus + conviction must NOT lift the Final
    Score back above that liquidity tier -- otherwise a thin name (e.g. an IDX
    stock with a 20-day average turnover under Rp5B, capped at 75) could be
    pushed to a BUY-grade score by the overlay, defeating the cap. When a
    ceiling is supplied the Final Score is clamped to it (the bonus can still
    fill any headroom *up to* the cap, but never breach it).
    """
    if not allow_bonus:
        return {
            "base_score": round(float(base_score), 1),
            "category_bonus": 0,
            "conviction_score": 0,
            "final_score": round(float(base_score), 1),
            "explore_tags": [],
            "conviction_reasons": [],
            "confirmations_fired": 0,
            "confirmations_total": confirmations_total(),
            "trade_ready": False,
        }
    bonus = category_bonus(cats)
    conviction = conviction_score(ind)
    final = explore_score(base_score, bonus, conviction)
    if score_ceiling is not None:
        final = round(min(final, float(score_ceiling)), 1)
    return {
        "base_score": round(float(base_score), 1),
        "category_bonus": bonus,
        "conviction_score": conviction,
        "final_score": final,
        "explore_tags": explore_tags(cats, ind),
        # Task A: transparency -- which confirmations fired and why.
        "conviction_reasons": conviction_reasons(ind),
        "confirmations_fired": confirmations_fired(ind),
        "confirmations_total": confirmations_total(),
        # Task C: trade-ready -- genuinely trending + confirmed, not overbought.
        "trade_ready": is_trade_ready(cats, ind),
    }


# --------------------------------------------------------------------------- #
# Task C: Trade-ready gate                                                     #
# --------------------------------------------------------------------------- #
# A conservative confluence flag. "Trade-ready" is NOT a prediction and NOT a
# promise -- it means the name's CURRENT technical posture clears a strict
# multi-factor bar: it is a bullish/pullback candidate AND its trend structure
# is up AND it has broad money-flow/trend confirmation AND it is not already
# overbought (so we're not buying straight into a pullback). This narrows the
# broad "bullish" tape into names actually set up to act on.
_TRADE_READY_MIN_CONFIRMATIONS = 4  # of 8 total


def is_trade_ready(cats: List[ScreenerCategory], ind: dict) -> bool:
    fired = conviction_signals(ind)
    bullish_cat = bool(
        cats
        and any(
            c in (ScreenerCategory.bullish, ScreenerCategory.pullback)
            for c in cats
        )
    )
    if not bullish_cat:
        return False
    if not fired.get("trend"):
        return False
    # Not overbought: RSI healthy band must hold (guards against buying a
    # blow-off top into a -1% stop).
    if not fired.get("rsi"):
        return False
    # Broad confirmation across the money-flow / trend battery.
    if confirmations_fired(ind) < _TRADE_READY_MIN_CONFIRMATIONS:
        return False
    return True


# --------------------------------------------------------------------------- #
# Tight-Stop Swing fit (SL -1% / TP +3% profile)                              #
# --------------------------------------------------------------------------- #
# A transparent, deterministic 0..100 *fit* gauge -- NOT a probability and NOT
# a prediction. It ranks how well a name's current technical posture matches a
# tight-stop swing plan: a -1% stop with a +3% target (risk:reward ~1:3).
#
# The dominant constraint is volatility. With a -1% stop, a name whose typical
# daily range (ATR%) is large will be stopped out by ordinary intraday noise
# before the +3% target is reached; a name that is too quiet rarely travels
# +3% in a swing window. The sweet spot for a -1%/+3% plan is a moderate ATR%
# (~1.5%-3.0%): enough room that -1% is not pure noise, yet a realistic path to
# +3%. On top of that, the setup is only attractive when the trend is already
# up (so +3% is the path of least resistance) and the name is NOT overbought
# (so it is not entered right before a pullback hits the tight stop).
#
# Pure function of the already-computed indicator dict. No I/O, no fetching.

# Component weights (sum = 100). Volatility dominates because it directly
# governs how often a -1% stop survives day-to-day noise.
_SWING_W_VOL = 45.0      # ATR% in the tight-stop sweet spot
_SWING_W_TREND = 25.0    # price above EMA20 + MACD histogram positive
_SWING_W_RSI = 15.0      # RSI in a healthy band (rising, not overbought)
_SWING_W_ADX = 15.0      # trend strength (a real trend, not chop)


def _swing_vol_fit(atr_pct: Optional[float]) -> float:
    """0..1 fit of ATR% for a -1% stop / +3% target.

    Peak fit at ~1.5%-3.0% ATR. Below ~0.8% the name is too quiet to reach +3%
    in a swing; above ~4% a -1% stop is inside one day's noise band.
    """
    if atr_pct is None:
        return 0.0
    a = float(atr_pct)
    if 1.5 <= a <= 3.0:
        return 1.0
    if 1.2 <= a < 1.5 or 3.0 < a <= 3.5:
        return 0.8
    if 0.8 <= a < 1.2 or 3.5 < a <= 4.5:
        return 0.5
    if 0.5 <= a < 0.8 or 4.5 < a <= 6.0:
        return 0.25
    return 0.0  # <0.5% (dead) or >6% (a -1% stop is pure noise)


def _swing_trend_fit(ind: dict) -> float:
    """0..1: price above EMA20 and MACD histogram positive (each half)."""
    close = ind.get("close")
    ema20 = ind.get("ema20")
    macd_hist = ind.get("macd_hist")
    score = 0.0
    if close is not None and ema20 is not None and close > ema20:
        score += 0.5
    if macd_hist is not None and macd_hist > 0:
        score += 0.5
    return score


def _swing_rsi_fit(rsi: Optional[float]) -> float:
    """0..1: RSI in a healthy, not-overbought band for a fresh entry.

    Best ~52-65 (rising momentum with room to run). Penalise overbought
    (>70, likely to pull back into a -1% stop) and weak/oversold (<45).
    """
    if rsi is None:
        return 0.0
    r = float(rsi)
    if 52 <= r <= 65:
        return 1.0
    if 48 <= r < 52 or 65 < r <= 70:
        return 0.6
    if 45 <= r < 48:
        return 0.3
    return 0.0


def _swing_adx_fit(adx: Optional[float]) -> float:
    """0..1: trend strength. A genuine trend (ADX>=25) helps +3% over noise."""
    if adx is None:
        return 0.0
    a = float(adx)
    if a >= 25:
        return 1.0
    if a >= 20:
        return 0.6
    if a >= 15:
        return 0.3
    return 0.0


def swing_fit_score(ind: dict) -> float:
    """0..100 fit for a tight-stop (-1%) / +3%-target swing entry.

    Deterministic, indicator-only. Higher = current posture matches the plan
    better (moderate volatility so -1% is not noise, an established up-trend so
    +3% is the path of least resistance, healthy non-overbought momentum).
    Returns 0 when the core indicators are missing (cannot assess fit).
    """
    if ind.get("close") is None:
        return 0.0
    vol = _swing_vol_fit(ind.get("atr_pct"))
    trend = _swing_trend_fit(ind)
    rsi = _swing_rsi_fit(ind.get("rsi"))
    adx = _swing_adx_fit(ind.get("adx"))
    total = (
        _SWING_W_VOL * vol
        + _SWING_W_TREND * trend
        + _SWING_W_RSI * rsi
        + _SWING_W_ADX * adx
    )
    return round(max(0.0, min(100.0, total)), 1)
