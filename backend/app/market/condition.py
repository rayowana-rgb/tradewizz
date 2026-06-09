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
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence


@dataclass(frozen=True)
class MarketCondition:
    condition: str          # EXTREME_FEAR..EXTREME_GREED | UNKNOWN
    condition_score: int    # 0..100 (50 when UNKNOWN)
    reason: str

    def to_dict(self) -> dict:
        return {
            "condition": self.condition,
            "condition_score": self.condition_score,
            "reason": self.reason,
        }


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


def classify_condition(
    closes: Optional[Sequence[float]],
    highs: Optional[Sequence[float]] = None,
    lows: Optional[Sequence[float]] = None,
) -> MarketCondition:
    """Classify market condition from index closes (oldest -> newest)."""
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
