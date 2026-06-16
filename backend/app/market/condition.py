"""Phase E: rule-based market condition (Fear / Greed) for an index.

Pure, deterministic, NO LLM. Maps an index's recent price action onto a
0..100 condition score and a five-band label:

    0-20  Extreme Fear
    21-40 Fear
    41-60 Neutral
    61-80 Greed
    81-100 Extreme Greed

Inputs are a list of index closes (oldest -> newest); optional highs/lows
sharpen the 52-week-range and volatility signals. Missing / insufficient data
yields a neutral ``UNKNOWN`` condition without crashing.

Signals (each nudges the score from a neutral 50 baseline):
  * Trend vs MA20 / MA50 / MA200 (above = greed, below = fear).
  * 20-day return (positive = greed, negative = fear).
  * Distance from the recent high / low (near high = greed, deep drawdown
    = fear).
  * Volatility (high realized volatility = fear).
  * RSI(14) of the index (overbought = greed, oversold = fear).
  * Market breadth (optional): advances vs declines across the universe.
    Captures hidden fragility/strength the headline index can hide (e.g. a
    handful of mega-caps lifting an index while most stocks fall).
  * Implied volatility / VIX (optional, US only): the market's forward-looking
    "fear gauge". Elevated VIX = fear; subdued VIX = complacency/greed.
The optional breadth/VIX signals are skipped gracefully when unavailable, so a
breadth-less or VIX-less market keeps the original price-only behaviour.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence


@dataclass(frozen=True)
class HorizonCondition:
    """A single timeframe's Fear/Greed reading (daily / weekly / monthly)."""

    horizon: str            # "daily" | "weekly" | "monthly"
    condition: str          # EXTREME_FEAR..EXTREME_GREED | UNKNOWN
    condition_score: int    # 0..100 (50 when UNKNOWN)
    reason: str
    available: bool = True

    def to_dict(self) -> dict:
        return {
            "horizon": self.horizon,
            "condition": self.condition,
            "condition_score": self.condition_score if self.available else None,
            "reason": self.reason,
            "available": self.available,
        }


@dataclass(frozen=True)
class MarketCondition:
    condition: str          # EXTREME_FEAR..EXTREME_GREED | UNKNOWN
    condition_score: int    # 0..100 (50 when UNKNOWN)
    reason: str
    # When the index itself is unavailable (no Yahoo symbol / no data) we emit
    # a null score so the client can distinguish "unknown because no data" from
    # a genuine neutral reading. ``available`` defaults True for back-compat.
    available: bool = True
    # Optional per-timeframe breakdown (daily / weekly / monthly). Omitted from
    # the response when None so legacy single-reading clients are unaffected.
    horizons: Optional[List["HorizonCondition"]] = None

    def to_dict(self) -> dict:
        out = {
            "condition": self.condition,
            "condition_score": self.condition_score if self.available else None,
            "reason": self.reason,
            "available": self.available,
        }
        if self.horizons is not None:
            out["horizons"] = [h.to_dict() for h in self.horizons]
        return out

    @classmethod
    def unavailable(
        cls, reason: str = "Index data unavailable"
    ) -> "MarketCondition":
        return cls("UNKNOWN", 50, reason, available=False)


def _label(score: float) -> str:
    if score <= 20:
        return "EXTREME_FEAR"
    if score <= 40:
        return "FEAR"
    if score <= 60:
        return "NEUTRAL"
    if score <= 80:
        return "GREED"
    return "EXTREME_GREED"


def _sma(values: Sequence[float], window: int) -> Optional[float]:
    if len(values) < window:
        return None
    return sum(values[-window:]) / window


def _rsi(closes: Sequence[float], period: int = 14) -> Optional[float]:
    if len(closes) < period + 1:
        return None
    gains = 0.0
    losses = 0.0
    for i in range(len(closes) - period, len(closes)):
        delta = closes[i] - closes[i - 1]
        if delta >= 0:
            gains += delta
        else:
            losses -= delta
    avg_gain = gains / period
    avg_loss = losses / period
    if avg_loss == 0:
        return 100.0 if avg_gain > 0 else 50.0
    rs = avg_gain / avg_loss
    return 100.0 - (100.0 / (1.0 + rs))


def _breadth_ratio(
    advances: Optional[int], declines: Optional[int]
) -> Optional[float]:
    """Net breadth in [-1, 1]: (adv - dec) / (adv + dec). None if no data.

    +1 = every stock up (broad strength), -1 = every stock down (broad
    capitulation), 0 = evenly split. ``unchanged`` deliberately ignored so a
    quiet market does not dilute the signal.
    """
    if advances is None or declines is None:
        return None
    total = advances + declines
    if total <= 0:
        return None
    return (advances - declines) / total


def classify_condition(
    closes: Optional[Sequence[float]],
    highs: Optional[Sequence[float]] = None,
    lows: Optional[Sequence[float]] = None,
    *,
    advances: Optional[int] = None,
    declines: Optional[int] = None,
    vix: Optional[float] = None,
) -> MarketCondition:
    """Classify market condition from index closes (oldest -> newest).

    Optional sentiment inputs (skipped gracefully when ``None``):
      * ``advances`` / ``declines``: universe breadth counts.
      * ``vix``: current implied-volatility / VIX level (US fear gauge).
    """
    if not closes or len([c for c in closes if c is not None]) < 25:
        return MarketCondition(
            "UNKNOWN", 50, "Insufficient index data to gauge market condition."
        )
    closes = [float(c) for c in closes if c is not None]
    last = closes[-1]

    score = 50.0
    bullish: List[str] = []
    bearish: List[str] = []

    ma20 = _sma(closes, 20)
    ma50 = _sma(closes, 50)
    ma200 = _sma(closes, 200)

    # Trend vs moving averages. Equality (a perfectly flat index) is neutral:
    # only a strict break above/below nudges the score.
    def _ma_signal(ma, up, down, label):
        nonlocal score
        if ma is None:
            return
        if last > ma * 1.001:
            score += up
            bullish.append(f"above its {label}")
        elif last < ma * 0.999:
            score -= down
            bearish.append(f"below its {label}")

    _ma_signal(ma20, 8, 8, "20-day average")
    _ma_signal(ma50, 8, 8, "50-day average")
    _ma_signal(ma200, 6, 10, "200-day average")

    # 20-day return.
    if len(closes) >= 21 and closes[-21] != 0:
        ret20 = last / closes[-21] - 1.0
        if ret20 >= 0.05:
            score += 12
            bullish.append("strong 20-day momentum")
        elif ret20 > 0:
            score += 5
        elif ret20 <= -0.05:
            score -= 12
            bearish.append("sharp 20-day decline")
        else:
            score -= 5

    # Distance from the recent high / low (use last ~252 sessions).
    window = closes[-252:]
    hi = max(highs[-252:]) if highs else max(window)
    lo = min(lows[-252:]) if lows else min(window)
    rng = hi - lo
    if hi > 0 and rng > 0:
        from_high = last / hi - 1.0  # <= 0
        if from_high >= -0.02:
            score += 10
            bullish.append("near its recent high")
        elif from_high <= -0.15:
            score -= 12
            bearish.append("in a significant drawdown")
        # Near the recent low only when genuinely in the bottom of the range
        # (not merely a flat market where high==low==last).
        if (last - lo) / rng <= 0.05:
            score -= 8
            bearish.append("near its recent low")

    # Realized volatility (std of daily returns over ~20d) -> fear when high.
    if len(closes) >= 21:
        rets = [
            closes[i] / closes[i - 1] - 1.0
            for i in range(len(closes) - 20, len(closes))
            if closes[i - 1] != 0
        ]
        if rets:
            mean = sum(rets) / len(rets)
            var = sum((r - mean) ** 2 for r in rets) / len(rets)
            vol = var ** 0.5
            if vol >= 0.03:
                score -= 10
                bearish.append("elevated volatility")
            elif vol <= 0.01:
                score += 4

    # RSI of the index.
    rsi = _rsi(closes)
    if rsi is not None:
        if rsi >= 70:
            score += 8
            bullish.append("overbought momentum")
        elif rsi <= 30:
            score -= 8
            bearish.append("oversold pressure")

    # Market breadth (optional): advances vs declines across the universe.
    # Surfaces fragility the headline index can hide. Scaled so a strongly
    # one-sided tape is worth up to +/-12 points; mild skews barely move it.
    breadth = _breadth_ratio(advances, declines)
    if breadth is not None:
        if breadth >= 0.30:
            score += 10
            bullish.append("broad participation")
        elif breadth >= 0.10:
            score += 4
        elif breadth <= -0.30:
            score -= 12
            bearish.append("broad selling")
        elif breadth <= -0.10:
            score -= 5

    # Implied volatility / VIX (optional, US only): the market's forward-looking
    # fear gauge. Conventional reading: <15 complacent, 15-20 calm, 20-30
    # cautious, >30 fearful, >40 panic.
    if vix is not None and vix > 0:
        if vix >= 40:
            score -= 16
            bearish.append("panic-level volatility (VIX)")
        elif vix >= 30:
            score -= 10
            bearish.append("elevated fear (VIX)")
        elif vix >= 22:
            score -= 4
            bearish.append("rising volatility (VIX)")
        elif vix <= 13:
            score += 8
            bullish.append("subdued volatility (VIX)")
        elif vix <= 17:
            score += 4

    score = max(0.0, min(100.0, score))
    label = _label(score)

    if label in ("GREED", "EXTREME_GREED"):
        drivers = ", ".join(bullish[:3]) or "positive momentum"
        reason = f"Index {drivers}."
    elif label in ("FEAR", "EXTREME_FEAR"):
        drivers = ", ".join(bearish[:3]) or "weak momentum"
        reason = f"Index {drivers}."
    else:
        reason = "Index is mixed with no decisive trend."

    return MarketCondition(label, int(round(score)), reason)


# --- Multi-horizon (daily / weekly / monthly) breakdown ---------------------
#
# The single ``classify_condition`` reading captures the market's *current*
# mood. Traders also care about the timeframe behind that mood: fear on the
# day inside a strong monthly uptrend is very different from fear on every
# timeframe. We therefore derive three Fear/Greed sub-readings from the SAME
# daily index series (no extra fetch, fully deterministic), each using a
# lookback appropriate to its horizon:
#
#   daily   -> last ~5 sessions  (this week's swing / today's mood)
#   weekly  -> last ~21 sessions (the past month of price action)
#   monthly -> last ~63 sessions (the past quarter / prevailing regime)
#
# Each sub-reading scores momentum, trend vs its own moving average, distance
# from the horizon's high/low, and RSI -- the same psychology, measured over
# the right window. Reusing the daily classifier's MA20/50/200 (calibrated for
# daily bars) on coarse resampled bars would be wrong (a "200-bar" monthly MA
# is ~16 years), so we use a dedicated, window-aware scorer here.

# (lookback sessions, MA window, RSI window, return window, label) per horizon.
_HORIZON_SPECS = [
    ("daily", 10, 5, 7, 3),
    ("weekly", 30, 10, 14, 5),
    ("monthly", 80, 20, 30, 20),
]


def _horizon_score(
    closes: Sequence[float],
    highs: Optional[Sequence[float]],
    lows: Optional[Sequence[float]],
    *,
    lookback: int,
    ma_window: int,
    rsi_window: int,
    ret_window: int,
) -> Optional[tuple]:
    """Score one horizon from the daily series. Returns (score, drivers) or None.

    Mirrors the psychology of ``classify_condition`` (trend / momentum / range
    position / RSI) but over a horizon-appropriate window, so each timeframe
    reflects its own regime.
    """
    if not closes or len(closes) < max(ma_window + 1, ret_window + 1, 12):
        return None
    last = closes[-1]
    score = 50.0
    bull: List[str] = []
    bear: List[str] = []

    # Trend vs the horizon's moving average.
    ma = _sma(closes, ma_window)
    if ma is not None:
        if last > ma * 1.001:
            score += 12
            bull.append(f"above its {ma_window}-session trend")
        elif last < ma * 0.999:
            score -= 12
            bear.append(f"below its {ma_window}-session trend")

    # Momentum over the return window.
    if len(closes) > ret_window and closes[-ret_window - 1] != 0:
        ret = last / closes[-ret_window - 1] - 1.0
        if ret >= 0.05:
            score += 14
            bull.append("strong momentum")
        elif ret > 0.01:
            score += 6
        elif ret <= -0.05:
            score -= 14
            bear.append("sharp decline")
        elif ret < -0.01:
            score -= 6

    # Position within the horizon's high/low range.
    win_c = closes[-lookback:]
    win_h = highs[-lookback:] if highs and len(highs) >= len(closes) else win_c
    win_l = lows[-lookback:] if lows and len(lows) >= len(closes) else win_c
    hi = max(win_h) if win_h else last
    lo = min(win_l) if win_l else last
    rng = hi - lo
    if rng > 0:
        pos = (last - lo) / rng  # 0 (at low) .. 1 (at high)
        if pos >= 0.90:
            score += 10
            bull.append("near range highs")
        elif pos <= 0.10:
            score -= 10
            bear.append("near range lows")

    # RSI over the horizon window.
    rsi = _rsi(closes, period=rsi_window)
    if rsi is not None:
        if rsi >= 70:
            score += 6
            bull.append("overbought")
        elif rsi <= 30:
            score -= 6
            bear.append("oversold")

    score = max(0.0, min(100.0, score))
    return score, (bull, bear)


def classify_multi_horizon(
    closes: Optional[Sequence[float]],
    highs: Optional[Sequence[float]] = None,
    lows: Optional[Sequence[float]] = None,
    *,
    advances: Optional[int] = None,
    declines: Optional[int] = None,
    vix: Optional[float] = None,
) -> MarketCondition:
    """Primary daily reading PLUS daily/weekly/monthly horizon breakdown.

    The returned ``MarketCondition`` keeps the same top-level fields as
    ``classify_condition`` (drop-in), and additionally carries a ``horizons``
    list with one :class:`HorizonCondition` per timeframe.

    Sentiment inputs (breadth, VIX) are point-in-time, so they nudge only the
    DAILY horizon (current mood). Weekly/monthly stay pure price action (the
    structural trend), so the breakdown isolates "today's mood" from "the
    prevailing regime".
    """
    primary = classify_condition(
        closes, highs, lows, advances=advances, declines=declines, vix=vix
    )

    clean = [float(c) for c in closes if c is not None] if closes else []
    horizons: List[HorizonCondition] = []

    for name, lookback, ma_window, rsi_window, ret_window in _HORIZON_SPECS:
        res = _horizon_score(
            clean, highs, lows,
            lookback=lookback, ma_window=ma_window,
            rsi_window=rsi_window, ret_window=ret_window,
        )
        if res is None:
            horizons.append(
                HorizonCondition(name, "UNKNOWN", 50,
                                 "Insufficient data for this horizon.",
                                 available=False)
            )
            continue
        score, (bull, bear) = res

        # The daily horizon reflects the current mood, so it also absorbs the
        # point-in-time sentiment inputs (breadth + VIX) that the headline uses.
        # This lets "daily" genuinely diverge from weekly/monthly (e.g. a fearful
        # day inside a calm monthly uptrend) instead of echoing the long-trend
        # headline.
        if name == "daily":
            breadth = _breadth_ratio(advances, declines)
            if breadth is not None:
                if breadth >= 0.30:
                    score += 8
                    bull.append("broad participation")
                elif breadth >= 0.10:
                    score += 3
                elif breadth <= -0.30:
                    score -= 10
                    bear.append("broad selling")
                elif breadth <= -0.10:
                    score -= 4
            if vix is not None and vix > 0:
                if vix >= 40:
                    score -= 14
                    bear.append("panic-level volatility")
                elif vix >= 30:
                    score -= 9
                    bear.append("elevated fear (VIX)")
                elif vix >= 22:
                    score -= 4
                elif vix <= 13:
                    score += 7
                    bull.append("subdued volatility")
                elif vix <= 17:
                    score += 3
            score = max(0.0, min(100.0, score))

        label = _label(score)
        if label in ("GREED", "EXTREME_GREED"):
            drivers = ", ".join(bull[:3]) or "positive momentum"
            reason = f"Index {drivers} over the {name} window."
        elif label in ("FEAR", "EXTREME_FEAR"):
            drivers = ", ".join(bear[:3]) or "weak momentum"
            reason = f"Index {drivers} over the {name} window."
        else:
            reason = f"Index is mixed over the {name} window."
        horizons.append(
            HorizonCondition(name, label, int(round(score)), reason)
        )

    return MarketCondition(
        primary.condition, primary.condition_score, primary.reason,
        available=primary.available, horizons=horizons,
    )
