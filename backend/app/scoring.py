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
# Factor weights (sum = 1.0).                                                  #
#                                                                             #
# Phase 11B — LIQUIDITY-FIRST. Market participation (liquidity) is now the     #
# single largest contributor, and a dedicated volume-expansion factor rewards  #
# rising participation. A stock is only investable if there is real two-sided  #
# market activity, so price pattern alone can no longer dominate the score.     #
#                                                                             #
#   Liquidity & Participation : 35%   (the "liquidity" factor)                  #
#   Trend                     : 20%                                            #
#   Momentum                  : 15%                                            #
#   Volume Expansion          : 15%   (the "volume_expansion" factor)           #
#   Relative Strength         :  5%                                            #
#   Market Regime             :  5%                                            #
#   Volatility / Risk         :  5%                                            #
# --------------------------------------------------------------------------- #
WEIGHTS = {
    "liquidity": 0.35,
    "trend": 0.20,
    "momentum": 0.15,
    "volume_expansion": 0.15,
    "relative_strength": 0.05,
    "market_regime": 0.05,
    "volatility": 0.05,
}

NEUTRAL = 50.0


# --------------------------------------------------------------------------- #
# Phase 11B: per-market participation thresholds (value traded, market         #
# currency). The dedicated liquidity participation score (0..100) is built     #
# from absolute value traded today, the smoothed 20-day average value traded,  #
# absolute volume, average 20-day volume, and the expansion ratios. These      #
# tiers express "very strong / strong / acceptable / weak / poor" turnover.    #
# --------------------------------------------------------------------------- #
# (very_strong, strong, acceptable, weak) in market currency. Below `weak`
# is "poor". Ordered high -> low.
PARTICIPATION_VALUE_TIERS = {
    Market.IDX: (50_000_000_000, 10_000_000_000, 5_000_000_000, 1_000_000_000),
    Market.US: (50_000_000, 10_000_000, 5_000_000, 1_000_000),
    Market.JAPAN: (5_000_000_000, 1_000_000_000, 500_000_000, 100_000_000),
    Market.INDIA: (5_000_000_000, 1_000_000_000, 500_000_000, 100_000_000),
    Market.VIETNAM: (
        100_000_000_000, 20_000_000_000, 10_000_000_000, 5_000_000_000,
    ),
    Market.SINGAPORE: (20_000_000, 5_000_000, 2_000_000, 500_000),
    Market.HKEX: (100_000_000, 20_000_000, 10_000_000, 3_000_000),
    Market.KOSPI: (50_000_000_000, 10_000_000_000, 5_000_000_000, 1_000_000_000),
    Market.KOSDAQ: (
        20_000_000_000, 5_000_000_000, 2_000_000_000, 500_000_000,
    ),
}


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

# --------------------------------------------------------------------------- #
# Liquidity cap tiers (Phase F). Per-market value-traded thresholds, expressed  #
# in the market's own currency. A stock whose value traded falls in a tier is   #
# *capped* at that tier's max score AFTER the full multi-factor + ML score is   #
# computed. Technical indicators can never override this cap. value_traded that #
# is 0 / null / missing is treated as fully illiquid -> max 50 + non-BUY.       #
#                                                                               #
# Each entry is an ordered list of (threshold, max_score): if value_traded is   #
# *below* `threshold`, the score is capped at `max_score`. The first matching   #
# (lowest) tier wins. Above the highest threshold there is NO cap.              #
# --------------------------------------------------------------------------- #
LIQUIDITY_CAP_TIERS = {
    Market.IDX: [
        (500_000_000, 50.0),     # < Rp500M
        (1_000_000_000, 60.0),   # < Rp1B
        (5_000_000_000, 75.0),   # < Rp5B
        (10_000_000_000, None),  # < Rp10B -> no cap at/above Rp10B
    ],
    Market.US: [
        (500_000, 50.0),     # < $500K
        (1_000_000, 60.0),   # < $1M
        (5_000_000, 75.0),   # < $5M
        (10_000_000, None),  # >= $10M no cap
    ],
    Market.JAPAN: [
        (50_000_000, 50.0),    # < ¥50M
        (100_000_000, 60.0),   # < ¥100M
        (500_000_000, 75.0),   # < ¥500M
    ],
    Market.INDIA: [
        (50_000_000, 50.0),    # < ₹50M
        (100_000_000, 60.0),   # < ₹100M
        (500_000_000, 75.0),   # < ₹500M
    ],
    Market.VIETNAM: [
        (5_000_000_000, 50.0),    # < ₫5B
        (10_000_000_000, 60.0),   # < ₫10B
        (50_000_000_000, 75.0),   # < ₫50B
    ],
    Market.SINGAPORE: [
        (250_000, 50.0),     # < S$250K
        (500_000, 60.0),     # < S$500K
        (2_000_000, 75.0),   # < S$2M
    ],
    Market.HKEX: [
        (1_000_000, 50.0),    # < HK$1M
        (3_000_000, 60.0),    # < HK$3M
        (10_000_000, 75.0),   # < HK$10M
    ],
    Market.KOSPI: [
        (500_000_000, 50.0),     # < ₩500M
        (1_000_000_000, 60.0),   # < ₩1B
        (5_000_000_000, 75.0),   # < ₩5B
    ],
    Market.KOSDAQ: [
        (500_000_000, 50.0),     # < ₩500M
        (1_000_000_000, 60.0),   # < ₩1B
        (5_000_000_000, 75.0),   # < ₩5B
    ],
}

# A stock at or below this absolute value traded is treated as fully
# illiquid / not investable regardless of market (hard floor).
ILLIQUID_MAX_SCORE = 50.0


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


def liquidity_floor_score(ind: dict, market: Optional[Market]) -> float:
    """Legacy: average daily value traded vs the per-market floor (0..100).

    Retained for backward compatibility / reference. The composite now uses
    :func:`participation_score`, a richer 0..100 gauge.
    """
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
# Phase 11B: dedicated liquidity participation score (0..100).                 #
# --------------------------------------------------------------------------- #
def _value_tier_points(value: Optional[float], tiers: tuple) -> float:
    """Map an absolute value-traded figure onto a 0..100 participation band.

    ``tiers`` is ``(very_strong, strong, acceptable, weak)``. Below ``weak`` is
    "poor" (heavily downgraded). Missing/zero -> 0 (no participation).
    """
    if value is None or value <= 0:
        return 0.0
    very_strong, strong, acceptable, weak = tiers
    if value >= very_strong:
        return 100.0
    if value >= strong:
        return 85.0
    if value >= acceptable:
        return 70.0
    if value >= weak:
        # Linear within the acceptable..weak band (45..70) so consistent,
        # decent turnover is rewarded over barely-investable names.
        span = acceptable - weak
        frac = (value - weak) / span if span > 0 else 0.0
        return 45.0 + max(0.0, min(1.0, frac)) * 25.0
    # Poor but non-zero turnover: graduate 0..45 by how close it is to the
    # weak threshold, so two illiquid names still rank by relative liquidity.
    frac = value / weak if weak > 0 else 0.0
    return max(5.0, min(1.0, frac) * 45.0)


def _expansion_points(ratio: Optional[float]) -> float:
    """Map a volume/value expansion ratio (today vs 20d avg) to 0..100."""
    if ratio is None or ratio <= 0:
        return NEUTRAL
    if ratio >= 3.0:
        return 100.0   # very strong participation spike
    if ratio >= 2.0:
        return 85.0    # strong
    if ratio >= 1.2:
        return 70.0    # healthy
    if ratio >= 0.8:
        return 50.0    # in line
    return 25.0        # weakening participation


# --------------------------------------------------------------------------- #
# Order-book tradability proxy (microstructure, from OHLCV only).             #
#                                                                             #
# Turnover alone (value traded) overstates how easy a name is to enter/exit. #
# A stock can post big value from a few block prints while its bid/offer      #
# queue is thin and gappy -- so price jumps for every order. With no Level-2  #
# depth we approximate that "tightness" from three OHLCV-derived signals and  #
# fold them into a 0..1 multiplier that DISCOUNTS the turnover-based          #
# participation score for high-value-but-thin names.                         #
#                                                                             #
#   illiquidity_impact   : price move per unit turnover (Amihud). High = bad. #
#   range_pct_20d        : daily High-Low swing %. High = jumpy/gappy tape.   #
#   zero_volume_days_20d : no-trade sessions. High = dead queue.             #
#                                                                             #
# The factor is bounded so it can only TRIM a turnover score (never inflate   #
# it) and degrades gracefully to 1.0 when the proxies are missing.           #
# --------------------------------------------------------------------------- #
# Thresholds calibrated against the real cross-market OHLCV distribution of
# illiquidity_impact (|return|/turnover, scaled): median ~1.7, p90 ~350,
# p99 ~7000. Normal names sit under ~2 (no penalty); the penalty ramps to full
# by the p90 tail (~300) where turnover is tiny and the tape is thin/dead. The
# range/zero-day distributions (median ~3.5%, p99 ~16%) anchor the other two.
_TRADABILITY_FLOOR = 0.55      # most a thin book can be discounted (-45%)
_IMPACT_SOFT = 2.0            # impact at/under this => no penalty (~median)
_IMPACT_HARD = 300.0         # impact at/over this => full impact penalty (~p90)
_RANGE_SOFT = 3.0             # daily swing %% at/under this => no penalty
_RANGE_HARD = 12.0           # daily swing %% at/over this => full penalty


def _lin_penalty(value: float, soft: float, hard: float) -> float:
    """0.0 at/under ``soft`` rising linearly to 1.0 at/over ``hard``."""
    if hard <= soft:
        return 0.0
    if value <= soft:
        return 0.0
    if value >= hard:
        return 1.0
    return (value - soft) / (hard - soft)


def tradability_factor(ind: dict) -> float:
    """0..1 multiplier discounting turnover for thin / gappy order books.

    1.0 == clean, tight, continuously-traded tape. Approaches
    ``_TRADABILITY_FLOOR`` for names whose price swings hard per rupiah traded
    (thin queue), trade in big jumps (gappy book), or routinely do not trade.
    Returns 1.0 when none of the proxies are available so it never
    destabilises data-light rows.
    """
    impact = ind.get("illiquidity_impact")
    range_pct = ind.get("range_pct_20d")
    zero_days = ind.get("zero_volume_days_20d")

    penalties = []
    if impact is not None and impact >= 0:
        penalties.append(_lin_penalty(float(impact), _IMPACT_SOFT, _IMPACT_HARD))
    if range_pct is not None and range_pct >= 0:
        penalties.append(_lin_penalty(float(range_pct), _RANGE_SOFT, _RANGE_HARD))
    if zero_days is not None:
        # Each no-trade day in 20 is a strong illiquidity tell; 4+ => full.
        penalties.append(_lin_penalty(float(zero_days), 0.0, 4.0))

    if not penalties:
        return 1.0

    # Worst single signal dominates (a thin book is a thin book even if one
    # proxy looks ok), softened by the average so one borderline reading does
    # not over-punish. 70%% worst / 30%% average.
    worst = max(penalties)
    avg = sum(penalties) / len(penalties)
    penalty = 0.70 * worst + 0.30 * avg
    factor = 1.0 - penalty * (1.0 - _TRADABILITY_FLOOR)
    return max(_TRADABILITY_FLOOR, min(1.0, factor))


def participation_score(ind: dict, market: Optional[Market]) -> float:
    """Liquidity & participation gauge (0..100) — the dominant scoring factor.

    Blends, with per-market thresholds:
      * today's value traded            (40%)
      * 20-day average value traded     (40%) — consistency of liquidity
      * today's volume vs 20-day average volume (10%)
      * 20-day average volume presence  (10%)

    Uses the *stricter* of today vs average value traded as the anchor so a
    single-day pump cannot fake durable liquidity. Missing turnover -> 0.
    """
    tiers = PARTICIPATION_VALUE_TIERS.get(
        market, PARTICIPATION_VALUE_TIERS[Market.IDX]
    )
    vt_today = ind.get("value_traded")
    avt_20d = ind.get("avg_value_traded_20d")
    if avt_20d is None:
        avt_20d = ind.get("avg_value_traded")

    # No turnover data at all -> no participation, lowest band.
    if (vt_today is None or vt_today <= 0) and (
        avt_20d is None or avt_20d <= 0
    ):
        return 0.0

    today_pts = _value_tier_points(vt_today, tiers)
    avg_pts = _value_tier_points(avt_20d, tiers)

    # Durable-liquidity anchor: the 20-day average is the truth about how liquid
    # the name is. Today's turnover can only *add* to it (a strong session
    # earns extra credit); a single quiet session must NOT drag a durably
    # liquid name down (this was the IDX liquidity-scoring bug). When there's
    # no average yet (data-light), fall back to today's band.
    if avt_20d is not None and avt_20d > 0:
        liq_pts = max(avg_pts, 0.5 * (today_pts + avg_pts))
    else:
        liq_pts = today_pts

    # Volume presence: today's volume relative to its 20-day average. A name
    # trading near/above its average volume earns the full volume slice.
    vol_ratio = ind.get("volume_ratio_20d")
    if vol_ratio is None:
        vol_ratio = ind.get("volume_ratio")
    vol_pts = _expansion_points(vol_ratio)

    # Average-volume presence: reward a meaningful, consistent share count.
    avg_vol = ind.get("avg_volume_20d")
    if avg_vol is None:
        avg_vol = ind.get("vol_mean_20")
    avgvol_pts = 100.0 if (avg_vol is not None and avg_vol > 0) else 0.0

    score = (
        0.80 * liq_pts
        + 0.10 * vol_pts
        + 0.10 * avgvol_pts
    )

    # Order-book tradability discount: a high-turnover name with a thin, gappy
    # queue (price jumps per rupiah traded, frequent no-trade days) is NOT as
    # liquid as its value traded suggests. Trim — never inflate — the score.
    score *= tradability_factor(ind)

    return _clamp(score)


def volume_expansion_score(ind: dict) -> float:
    """Rising participation: volume_ratio_20d + value_traded_ratio_20d (0..100).

    Expanding volume AND turnover versus their 20-day averages signals fresh
    money entering the name. Falls back to neutral when ratios are absent so
    the factor never destabilises data-light rows.
    """
    vol_ratio = ind.get("volume_ratio_20d")
    if vol_ratio is None:
        vol_ratio = ind.get("volume_ratio")
    val_ratio = ind.get("value_traded_ratio_20d")

    if vol_ratio is None and val_ratio is None:
        return NEUTRAL

    pts = []
    if vol_ratio is not None:
        pts.append(_expansion_points(vol_ratio))
    if val_ratio is not None:
        pts.append(_expansion_points(val_ratio))
    return _clamp(sum(pts) / len(pts))


# Backward-compatible alias: the composite's "liquidity" factor now maps to the
# richer participation score. Older imports of ``liquidity_score`` keep working.
def liquidity_score(ind: dict, market: Optional[Market]) -> float:
    """Liquidity & participation factor (0..100). See participation_score."""
    return participation_score(ind, market)


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

    # Phase 11B: a fully bearish EMA stack (ema20 < ema50 < ema200) means the
    # name is in a confirmed downtrend. Liquidity now carries 35% of the
    # composite, so without this guard a high-turnover stock could be floated
    # out of SELL purely on participation. The penalty re-asserts trend so a
    # liquid downtrend stays bearish, while a liquid *uptrend* is unaffected.
    ema200 = ind.get("ema200")
    if ema200 is None:
        ema200 = ind.get("sma200")
    if (
        ema20 is not None
        and ema50 is not None
        and ema200 is not None
        and ema20 < ema50 < ema200
    ):
        penalty += 18.0

    return penalty


# --------------------------------------------------------------------------- #
# Composite + calibration                                                     #
# --------------------------------------------------------------------------- #
def factor_breakdown(
    ind: dict, ctx: Optional[MarketContext], market: Optional[Market]
) -> dict:
    """All weighted factor scores (0..100) keyed by name (tests/debug).

    Phase 11B: ``liquidity`` is the participation score (dominant 35%) and a
    new ``volume_expansion`` factor (15%) rewards rising participation.
    """
    return {
        "liquidity": participation_score(ind, market),
        "trend": trend_score(ind),
        "momentum": momentum_score(ind),
        "volume_expansion": volume_expansion_score(ind),
        "relative_strength": relative_strength_score(ctx),
        "market_regime": market_regime_score(ctx),
        "volatility": volatility_score(ind),
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


# --------------------------------------------------------------------------- #
# Phase F: liquidity cap (applied AFTER the final calibrated/ML score).         #
# --------------------------------------------------------------------------- #
def _value_traded(ind: dict) -> Optional[float]:
    """Liquidity-cap anchor: a name's *durable* daily value traded.

    Anchors on the **20-day average** turnover, which captures how liquid the
    name really is and resists single-day noise in BOTH directions:

    * A single-day *pump* lifts today's turnover but barely moves the 20-day
      average, so it can't bypass the cap (the original Phase 11B concern).
    * A single-day *lull* (a genuinely liquid name having one thin session)
      no longer drags the anchor down to that quiet day. This was the IDX bug:
      a name like GOTO (≈Rp19B/day average) was being capped on a Rp2.5B day
      because the anchor used ``min(today, avg)``.

    Falls back to today's turnover only when no 20-day average is available
    (data-light rows). When neither is available the name is treated as fully
    illiquid (None -> cap).
    """
    def _f(v) -> Optional[float]:
        try:
            return float(v) if v is not None else None
        except (TypeError, ValueError):
            return None

    today = _f(ind.get("value_traded"))
    avg = _f(ind.get("avg_value_traded_20d"))
    if avg is None:
        avg = _f(ind.get("avg_value_traded"))

    # Prefer the durable 20-day average; fall back to today when it's the only
    # turnover figure we have.
    if avg is not None:
        return avg
    return today


def liquidity_cap_for(
    value_traded: Optional[float], market: Optional[Market]
) -> tuple[Optional[float], bool, Optional[str]]:
    """Return ``(max_score, illiquid, reason)`` for a given value traded.

    * ``max_score`` is ``None`` when the name is liquid enough to be uncapped.
    * ``illiquid`` is True when value traded is 0 / null / tiny enough that the
      stock is *not investable* (max score 50, never BUY).
    * ``reason`` is a short human explanation when a cap applies, else None.

    Pure: no I/O. Used both by the engine (to cap scores) and by the screener /
    radar / hero filters (to exclude or warn).
    """
    # Missing, null, zero, or negative -> fully illiquid.
    if value_traded is None or value_traded <= 0:
        return (
            ILLIQUID_MAX_SCORE,
            True,
            "Liquidity cap applied: no value traded — illiquid, not investable.",
        )

    tiers = LIQUIDITY_CAP_TIERS.get(market)
    if tiers is None:
        # Unknown market: be conservative using the IDX-equivalent tiers.
        tiers = LIQUIDITY_CAP_TIERS[Market.IDX]

    for threshold, max_score in tiers:
        if value_traded < threshold:
            if max_score is None:
                return (None, False, None)
            illiquid = max_score <= ILLIQUID_MAX_SCORE
            reason = (
                "Liquidity cap applied: value traded below investable "
                f"threshold (capped at {max_score:.0f})."
            )
            return (max_score, illiquid, reason)
    # At or above the top threshold: no cap.
    return (None, False, None)


def apply_liquidity_cap(
    score: float, signal: str, ind: dict, market: Optional[Market]
) -> tuple[float, str, bool, Optional[str]]:
    """Cap a *final* score/signal by liquidity. Returns the adjusted tuple.

    ``(capped_score, capped_signal, illiquid, reason)``. The technical /ML
    score can NEVER push an illiquid name above its liquidity tier, and an
    illiquid name can never carry a BUY signal. Liquid names pass through
    unchanged.
    """
    vt = _value_traded(ind)
    max_score, illiquid, reason = liquidity_cap_for(vt, market)
    if max_score is None:
        return score, signal, False, None
    capped = min(score, max_score)
    new_signal = signal
    # Illiquid names must never be BUY; re-derive the signal from the capped
    # score and additionally forbid BUY when flagged illiquid.
    new_signal = signal_for_score(capped)
    if illiquid and new_signal == "BUY":
        new_signal = "HOLD"
    return capped, new_signal, illiquid, reason
