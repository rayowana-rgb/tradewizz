"""Deterministic mock data generators.

These mirror the Flutter app's local mock builders (`lib/services/api_client.dart`)
so the backend's placeholder output is shaped exactly like the client expects.
Swap these for the real screening engine when the Telegram bot is migrated.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import List

from .models import (
    AnalysisResult,
    Market,
    ScreenerCategory,
    ScreenerMatch,
    ScreenerResult,
    WeeklyPrediction,
)

# Same category rotation the Flutter mock uses, for parity.
_CATEGORY_ROTATION: List[List[ScreenerCategory]] = [
    [ScreenerCategory.bullish, ScreenerCategory.ara_hunter],
    [ScreenerCategory.bearish, ScreenerCategory.short_candidate],
    [ScreenerCategory.scalping, ScreenerCategory.frequently_traded],
    [ScreenerCategory.accumulation, ScreenerCategory.pullback],
    [ScreenerCategory.accumulation_silent],
    [ScreenerCategory.turnaround_multibagger, ScreenerCategory.bullish],
    [ScreenerCategory.pullback, ScreenerCategory.accumulation],
    [ScreenerCategory.frequently_traded],
    [ScreenerCategory.ara_hunter, ScreenerCategory.scalping],
    [ScreenerCategory.short_candidate],
]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _seed(symbol: str) -> int:
    """Stable hash matching the Dart `_seed` (h = h*31 + c, masked to 31 bits)."""
    h = 0
    for ch in symbol.upper():
        h = (h * 31 + ord(ch)) & 0x7FFFFFFF
    return h


def mock_analyze(symbol: str, market: Market) -> AnalysisResult:
    sym = symbol.upper()
    score = _seed(sym) % 100
    if score > 66:
        signal = "BUY"
    elif score > 33:
        signal = "HOLD"
    else:
        signal = "SELL"

    return AnalysisResult(
        symbol=sym,
        market=market,
        signal=signal,
        score=float(score),
        summary=(
            f"{sym} shows a {signal} bias on {market.value}. This is placeholder "
            "output; the migrated screening engine will populate real metrics."
        ),
        highlights=[
            f"Momentum: {'positive' if score > 50 else 'weak'}",
            f"Relative strength vs {market.value}: "
            f"{'leader' if score > 60 else 'lagger'}",
            f"Volume trend: {'rising' if score % 2 == 0 else 'flat'}",
        ],
        generated_at=_now_iso(),
    )


def mock_predict_weekly(symbol: str) -> WeeklyPrediction:
    sym = symbol.upper()
    s = _seed(sym)
    if s % 3 == 0:
        direction = "UP"
    elif s % 3 == 1:
        direction = "DOWN"
    else:
        direction = "FLAT"

    return WeeklyPrediction(
        symbol=sym,
        direction=direction,
        expected_change_percent=((s % 7) - 3) * 0.9,
        confidence=0.5 + (s % 50) / 100,
        rationale=(
            f"Placeholder weekly forecast for {sym}. Real prediction will come "
            "from the migrated model."
        ),
    )


def mock_screener_match(
    symbol: str, market: Market, name: str = ""
) -> ScreenerMatch:
    """Deterministic per-symbol screener match (for graceful /screen fallback).

    Used when a real fetch fails for a single symbol, so the universe still
    returns a populated, stable row instead of dropping the symbol.
    """
    sym = symbol.upper()
    s = _seed(sym)
    score = float(s % 100)
    cats = _CATEGORY_ROTATION[s % len(_CATEGORY_ROTATION)]
    bearish = (
        ScreenerCategory.bearish in cats
        or ScreenerCategory.short_candidate in cats
    )
    if bearish:
        signal = "SELL"
    elif score > 66:
        signal = "BUY"
    else:
        signal = "HOLD"
    # Stable pseudo price/change derived from the seed.
    price = round(100 + (s % 9000) / 10.0, 2)
    change = round(((s % 21) - 10) * 0.3, 2)
    return ScreenerMatch(
        symbol=sym,
        name=name or sym,
        score=score,
        signal=signal,
        price=price,
        change_percent=change,
        categories=cats,
    )


def mock_screen(market: Market) -> ScreenerResult:
    matches: List[ScreenerMatch] = []
    for i, cats in enumerate(_CATEGORY_ROTATION):
        score = 95 - i * 6
        bearish = (
            ScreenerCategory.bearish in cats
            or ScreenerCategory.short_candidate in cats
        )
        if bearish:
            signal = "SELL"
        elif score > 66:
            signal = "BUY"
        else:
            signal = "HOLD"

        matches.append(
            ScreenerMatch(
                symbol=f"{market.value}{i + 1:02d}",
                name=f"Sample {market.value} Co. {i + 1}",
                score=float(score),
                signal=signal,
                price=1000 + i * 137.0,
                change_percent=(-1 if bearish else 1) * (i % 5 + 1) * 0.8,
                categories=cats,
            )
        )

    return ScreenerResult(
        market=market,
        matches=matches,
        generated_at=_now_iso(),
    )
