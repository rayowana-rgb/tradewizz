"""Institutional-grade multi-factor composite scoring.

Turns the raw indicator dict (``indicators.compute_all``) plus an optional
:class:`MarketContext` (relative strength vs the market index + market regime)
into a single 0..100 *technical* score that approximates trade-success
probability and overall stock quality.

Design goals
------------
* **Weighted composite** of seven factors (Phase 1), each 0..100:
    Trend 25%, Momentum 20%, Volume 15%, Relative Strength 15%,
    Volatility 10%, Market Regime 10%, Liquidity 5%.
* **Hard quality penalties** (Phase 2) subtract from the composite so a
  pump-and-dump / gap / illiquid / micro-price name can't rank highly on a
  momentary RSI/volume spike.
* **ML blend** (Phase 3) is applied in the engine:
    ``final = 0.7 * technical + 0.3 * (100 * win_probability)``.
* **Calibration** (Phase 4): a monotonic curve compresses the mid-range and
  reserves the 90+ band for genuine multi-factor confluence, so only a small
  fraction of any universe reaches "elite".

Robustness
----------
Every factor degrades to a neutral 50 when its inputs are missing, so the
synthetic-fetcher unit tests (which omit the market context) still produce
stable, monotonic scores. Applied identically to ALL markets — the only
market-specific input is the per-market liquidity floor.

This module is pure (no I/O, no network); the engine supplies data + context.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .models import Market

# --------------------------------------------------------------------------- #
# Factor weights (sum = 1.0). Phase 1 spec.                                    #
# --------------------------------------------------------------------------- #
WEIGHTS = {
    "trend": 0.25,
    "momentum": 0.20,
    "volume": 0.15,
    "relative_strength": 0.15,
    "volatility": 0.10,
    "market_regime": 0.10,
    "liquidity": 0.05,
}

NEUTRAL = 50.0


# Per-market minimum Average Daily Value Traded for a full liquidity score,
# expressed in the market's own currency (Phase 1 spec).
LIQUIDITY_FLOOR = {
    Market.US: 2_000_000,        # $2M
    Market.IDX: 10_000_000_000,  # Rp10B
    Market.JAPAN: 200_000_000,   # ¥200M
    Market.INDIA: 100_000_000,   # ₹100M
    Market.VIETNAM: 20_000_000_000,  # ₫20B
    Market.SINGAPORE: 1_000_000,     # S$1M
    # Pre-existing markets keep sensible floors (FX-scaled order of magnitude).
    Market.HKEX: 5_000_000,      # HK$5M
    Market.KOSPI: 1_000_000_000,    # ₩1B
    Market.KOSDAQ: 500_000_000,     # ₩500M
}

# Minimum price (in the market's currency) below which a name is penalized as a
# sub-dollar-equivalent micro stock (Phase 2). FX order-of-magnitude.
MIN_PRICE_EQUIV = {
    Market.US: 1.0,            # $1
    Market.IDX: 50.0,          # ~ sub-Rp50 lottery tickets
    Market.JAPAN: 100.0,       # ¥100
    Market.INDIA: 10.0,        # ₹10
    Market.VIETNAM: 2_000.0,   # ₫2,000
    Market.SINGAPORE: 0.20,    # S$0.20
    Market.HKEX: 0.50,         # HK$0.50
    Market.KOSPI: 1_000.0,     # ₩1,000
    Market.KOSDAQ: 1_000.0,    # ₩1,000
}


@dataclass
class MarketContext:
    """Cross-sectional context for relative strength + market regime.

    All fields optional; when absent the corresponding factor falls back to a
    neutral 50 so the composite stays well-defined.

    rs_value:        stock_return_3m - index_return_3m (fraction, e.g. 0.08).
    rs_percentile:   0..1 cross-sectional rank of rs_value within the market
                     universe, if a ranking pass computed it; else None and the
                     score is derived from rs_value thresholds.
    regime:          "bull" | "bear" | "neutral" from the index EMA50/EMA200.
    """

    rs_value: Optional[float] = None
    rs_percentile: Optional[float] = None
    regime: Optional[str] = None


def _clamp(v: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, v))


# --------------------------------------------------------------------------- #
# Phase 1 factor scores                                                       #
# --------------------------------------------------------------------------- #
def trend_score(ind: dict) -> float:
    """EMA20/50/200 alignment + above-EMA200 + 52w-high bonuses (0..100)."""
    ema20 = ind.get("ema20")
    ema50 = ind.get("ema50")
    ema200 = ind.get("ema200")
    if ema200 is None:
        # Fall back to SMA200 (already computed) when EMA200 isn't available.
        ema200 = ind.get("sma200")
    close = ind.get("close")

    if ema20 is None or ema50 is None:
        return NEUTRAL

    # Base alignment.
    if ema200 is not None and ema20 > ema50 > ema200:
        base = 100.0
    elif ema200 is not None and ema20 < ema50 < ema200:
        base = 0.0
    elif ema20 > ema50:
        base = 70.0
    else:  # ema20 < ema50 (no full bearish stack)
        base = 30.0

    bonus = 0.0
    if close is not None and ema200 is not None and close > ema200:
        bonus += 10.0
    # New 52-week high: latest close at/above the rolling 52w (252d) high.
    high_52w = ind.get("high_52w")
    if (
        close is not None
        and high_52w is not None
        and close >= high_52w * 0.999  # within rounding of the high
    ):
        bonus += 15.0

    return _clamp(base + bonus)


def momentum_score(ind: dict) -> float:
    """RSI band + MACD histogram + ROC + ADX (0..100), penalizing extremes."""
    rsi = ind.get("rsi")
    macd_hist = ind.get("macd_hist")
    roc = ind.get("roc")
    adx = ind.get("adx")

    if rsi is None and macd_hist is None and roc is None and adx is None:
        return NEUTRAL

    score = NEUTRAL

    # RSI: 55-70 optimal; >85 extreme overbought penalty; <30 oversold caution.
    if rsi is not None:
        if 55 <= rsi <= 70:
            score += 20.0
        elif 50 <= rsi < 55:
            score += 10.0
        elif 70 < rsi <= 80:
            score += 5.0
        elif rsi > 85:
            score -= 25.0
        elif 80 < rsi <= 85:
            score -= 10.0
        elif 40 <= rsi < 50:
            score -= 5.0
        elif rsi < 30:
            score -= 10.0

    # MACD histogram positive => momentum confirmation.
    if macd_hist is not None:
        score += 10.0 if macd_hist > 0 else -10.0

    # Rate of change (12-period) sign + magnitude.
    if roc is not None:
        if roc > 5:
            score += 10.0
        elif roc > 0:
            score += 5.0
        elif roc < -5:
            score -= 10.0
        else:
            score -= 5.0

    # ADX > 25 => a real (tradeable) trend; weak trend gets nothing.
    if adx is not None:
        if adx >= 25:
            score += 10.0
        elif adx >= 20:
            score += 5.0

    return _clamp(score)


def volume_score(ind: dict) -> float:
    """Volume-ratio surge + CMF sign + OBV trend (0..100)."""
    # Prefer the 5d-vs-20d ratio (Phase 1 spec); fall back to the single-bar
    # latest/20d ratio when the short window isn't available.
    vr = ind.get("vol_ratio_5_20")
    if vr is None:
        vr = ind.get("volume_ratio")
    cmf = ind.get("cmf")
    obv = ind.get("obv")
    obv_prev = ind.get("obv_prev")

    if vr is None and cmf is None and obv is None:
        return NEUTRAL

    score = 0.0
    have = 0

    # Volume ratio 5d/20d (or latest/20d): >2 strong, >1.2 mild.
    if vr is not None:
        have += 1
        if vr > 2.0:
            score += 30.0
        elif vr > 1.2:
            score += 20.0
        elif vr > 0.8:
            score += 12.0
        else:
            score += 4.0

    # Chaikin Money Flow positive => accumulation.
    if cmf is not None:
        have += 1
        if cmf > 0.1:
            score += 30.0
        elif cmf > 0:
            score += 20.0
        elif cmf > -0.1:
            score += 8.0
        else:
            score += 0.0

    # OBV rising.
    if obv is not None and obv_prev is not None:
        have += 1
        score += 40.0 if obv > obv_prev else 5.0

    if have == 0:
        return NEUTRAL
    # The three sub-scores are designed to total 100 when all present; when only
    # some are available, renormalize so the factor stays on a 0..100 scale.
    max_possible = (30.0 if vr is not None else 0.0) + (
        30.0 if cmf is not None else 0.0
    ) + (40.0 if (obv is not None and obv_prev is not None) else 0.0)
    if max_possible <= 0:
        return NEUTRAL
    return _clamp(score / max_possible * 100.0)


def relative_strength_score(ctx: Optional[MarketContext]) -> float:
    """Stock vs index 3-month outperformance (0..100).

    Prefers a cross-sectional percentile when the ranking pass supplies it;
    otherwise maps the raw RS spread (stock_return_3m - index_return_3m) onto
    the Top-10%/Top-25%/Middle/Bottom bands via fixed thresholds.
    """
    if ctx is None:
        return NEUTRAL

    if ctx.rs_percentile is not None:
        p = ctx.rs_percentile
        if p >= 0.90:
            return 100.0
        if p >= 0.75:
            return 80.0
        if p >= 0.25:
            return 50.0
        return 20.0

    rs = ctx.rs_value
    if rs is None:
        return NEUTRAL
    # Threshold mapping when no universe percentile is available.
    if rs >= 0.15:        # outperforming by 15%+ over 3m -> elite
        return 100.0
    if rs >= 0.05:        # +5%..15% -> strong
        return 80.0
    if rs > -0.05:        # roughly in line -> middle
        return 50.0
    return 20.0           # clear laggard


def volatility_score(ind: dict) -> float:
    """ATR% sweet spot for swing trading: 2%-6% ideal (0..100)."""
    atr_pct = ind.get("atr_pct")
    if atr_pct is None:
        return NEUTRAL
    a = atr_pct
    if 2.0 <= a <= 6.0:
        return 100.0
    if 1.5 <= a < 2.0 or 6.0 < a <= 8.0:
        return 75.0
    if 1.0 <= a < 1.5 or 8.0 < a <= 10.0:
        return 50.0
    if a < 1.0:           # too quiet -> little opportunity
        return 30.0
    if 10.0 < a <= 15.0:  # hot
        return 30.0
    return 10.0           # >15% -> erratic / dangerous


def market_regime_score(ctx: Optional[MarketContext]) -> float:
    """Bull/bear regime from the index EMA50 vs EMA200 (0..100)."""
    if ctx is None or ctx.regime is None:
        return NEUTRAL
    if ctx.regime == "bull":
        return 100.0
    if ctx.regime == "bear":
        return 20.0
    return 50.0  # neutral / unknown


def liquidity_score(ind: dict, market: Optional[Market]) -> float:
    """Average daily value traded vs the per-market floor (0..100)."""
    adv = ind.get("avg_value_traded")
    if adv is None:
        adv = ind.get("value_traded")  # fall back to latest day's turnover
    if adv is None:
        return NEUTRAL
    floor = LIQUIDITY_FLOOR.get(market, LIQUIDITY_FLOOR[Market.IDX])
    if floor <= 0:
        return NEUTRAL
    ratio = adv / floor
    if ratio >= 5:
        return 100.0
    if ratio >= 2:
        return 85.0
    if ratio >= 1:
        return 70.0
    if ratio >= 0.5:
        return 45.0
    if ratio >= 0.2:
        return 25.0
    return 10.0


# --------------------------------------------------------------------------- #
# Phase 2 hard quality penalties                                              #
# --------------------------------------------------------------------------- #
def quality_penalty(ind: dict, market: Optional[Market]) -> float:
    """Sum of hard penalties (>= 0) to subtract from the composite.

    Catches gap-ups, pump-and-dump, untrended volume spikes, extreme ATR, and
    sub-$1-equivalent micro prices. Returns a non-negative magnitude.
    """
    penalty = 0.0

    close = ind.get("close")
    prev_close = ind.get("prev_close")
    vr = ind.get("volume_ratio")
    atr_pct = ind.get("atr_pct")
    ema20 = ind.get("ema20")
    ema50 = ind.get("ema50")
    pct_change_3 = ind.get("pct_change_3")
    rsi = ind.get("rsi")

    # Gap > 20% vs prior close.
    if close is not None and prev_close not in (None, 0):
        gap = abs(close / prev_close - 1.0)
        if gap > 0.20:
            penalty += 20.0

    # Pump-and-dump: huge 3-day surge + extreme RSI + no durable trend.
    untrended = not (ema20 is not None and ema50 is not None and ema20 > ema50)
    if (
        pct_change_3 is not None
        and pct_change_3 > 0.40           # +40% in 3 days
        and rsi is not None and rsi > 80  # blow-off
        and untrended
    ):
        penalty += 30.0

    # Volume spike >10x without an established trend.
    if vr is not None and vr > 10.0 and untrended:
        penalty += 25.0

    # ATR > 15% -> uninvestable volatility.
    if atr_pct is not None and atr_pct > 15.0:
        penalty += 20.0

    # Sub-$1-equivalent micro price.
    min_price = MIN_PRICE_EQUIV.get(market, MIN_PRICE_EQUIV[Market.IDX])
    if close is not None and close < min_price:
        penalty += 15.0

    return penalty


# --------------------------------------------------------------------------- #
# Composite + calibration                                                     #
# --------------------------------------------------------------------------- #
def factor_breakdown(
    ind: dict, ctx: Optional[MarketContext], market: Optional[Market]
) -> dict:
    """All seven factor scores (0..100) keyed by name. Useful for tests/debug."""
    return {
        "trend": trend_score(ind),
        "momentum": momentum_score(ind),
        "volume": volume_score(ind),
        "relative_strength": relative_strength_score(ctx),
        "volatility": volatility_score(ind),
        "market_regime": market_regime_score(ctx),
        "liquidity": liquidity_score(ind, market),
    }


def composite_raw(
    ind: dict, ctx: Optional[MarketContext], market: Optional[Market]
) -> float:
    """Weighted factor composite minus hard penalties, clamped to 0..100."""
    factors = factor_breakdown(ind, ctx, market)
    weighted = sum(factors[name] * WEIGHTS[name] for name in WEIGHTS)
    weighted -= quality_penalty(ind, market)
    return _clamp(weighted)


def calibrate(raw: float) -> float:
    """Map a raw composite (0..100) onto the calibrated distribution.

    Goals (Phase 4): reserve 90-100 for genuine confluence (only a few % of a
    universe), keep 80-89 for strong candidates, 70-79 watchlist, 60-69
    neutral, <60 avoid. We compress the top: a raw composite must be very high
    (broad multi-factor agreement) to clear 90. The curve is monotonic so
    ranking order is preserved.
    """
    r = _clamp(raw)
    # Piecewise-linear monotonic remap. The knees push the bulk of names into
    # the 50-85 range and steeply gate the 90+ elite band.
    #   raw  0   -> 0
    #   raw 50   -> 55
    #   raw 70   -> 72
    #   raw 85   -> 84
    #   raw 92   -> 90      (elite gate)
    #   raw 100  -> 100
    points = [
        (0.0, 0.0),
        (50.0, 55.0),
        (70.0, 72.0),
        (85.0, 84.0),
        (92.0, 90.0),
        (100.0, 100.0),
    ]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if r <= x1:
            if x1 == x0:
                return y1
            t = (r - x0) / (x1 - x0)
            return _clamp(y0 + t * (y1 - y0))
    return 100.0


def technical_score(
    ind: dict, ctx: Optional[MarketContext], market: Optional[Market]
) -> float:
    """Calibrated 0..100 technical score (pre-ML)."""
    return calibrate(composite_raw(ind, ctx, market))


def blend_with_ml(technical: float, win_probability: Optional[float]) -> float:
    """final = 0.7*technical + 0.3*(100*win_prob) when a model exists.

    With no model the technical score is returned unchanged.
    """
    if win_probability is None:
        return _clamp(technical)
    wp = max(0.0, min(1.0, win_probability))
    return _clamp(0.7 * technical + 0.3 * (100.0 * wp))


def signal_for_score(score: float) -> str:
    """BUY/HOLD/SELL bands aligned with the calibrated distribution."""
    if score >= 70:
        return "BUY"
    if score >= 50:
        return "HOLD"
    return "SELL"
