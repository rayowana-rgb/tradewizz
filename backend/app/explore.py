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
CONVICTION_MAX = 20


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
# Rule 4: Conviction Score (0..20)                                            #
# --------------------------------------------------------------------------- #
# Six independent money-flow / trend-quality confirmations, each worth a slice
# of the 0..20 range. Ported conceptually from bot9 analyze_screened_stocks'
# buy-signal confirmation block (CMF>0, OBV rising, ADX>25, volume spike,
# MACD bullish crossover, RSI in a healthy quality band).
_CONVICTION_POINTS = {
    "cmf": 4,        # Strong CMF: positive Chaikin money flow
    "obv": 4,        # Strong OBV: rising on-balance volume
    "adx": 4,        # Strong ADX: trend strength > 25
    "volume": 3,     # Volume confirmation (spike vs 10d avg)
    "macd": 3,       # MACD bullish confirmation
    "rsi": 2,        # RSI quality band (healthy, not overbought/oversold)
}


def conviction_signals(ind: dict) -> Dict[str, bool]:
    """Return which conviction confirmations fired (booleans).

    Each is independently ``None``-safe; a missing indicator simply doesn't
    fire. Mirrors the bot9 confirmation gates used in analyze_screened_stocks.
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
    }


def conviction_score(ind: dict) -> int:
    """0..20 conviction from the six money-flow / trend confirmations."""
    fired = conviction_signals(ind)
    total = sum(_CONVICTION_POINTS[k] for k, ok in fired.items() if ok)
    return max(0, min(CONVICTION_MAX, total))


# --------------------------------------------------------------------------- #
# Rule 5: Final Explore Score                                                  #
# --------------------------------------------------------------------------- #
def explore_score(
    base_score: float, bonus: int, conviction: int
) -> float:
    """Final Explore Score = clamp(base + bonus + conviction, 0..100)."""
    total = float(base_score) + float(bonus) + float(conviction)
    return round(max(0.0, min(100.0, total)), 1)


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
    }
