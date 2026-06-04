"""Pydantic models that exactly match the TradeWiz Flutter app's JSON contract.

Field names use snake_case to match the Dart `fromJson` parsers
(e.g. `generated_at`, `change_percent`, `expected_change_percent`).
"""

from __future__ import annotations

from enum import Enum
from typing import List

from pydantic import BaseModel, Field


class Market(str, Enum):
    """Supported market codes (mirrors the Flutter `Market` enum codes)."""

    IDX = "IDX"
    HKEX = "HKEX"
    KOSPI = "KOSPI"
    KOSDAQ = "KOSDAQ"


class ScreenerCategory(str, Enum):
    """Screener category wire names (match the Flutter `ScreenerCategory`)."""

    bullish = "bullish"
    bearish = "bearish"
    scalping = "scalping"
    accumulation = "accumulation"
    pullback = "pullback"
    accumulation_silent = "accumulation_silent"
    turnaround_multibagger = "turnaround_multibagger"
    frequently_traded = "frequently_traded"
    short_candidate = "short_candidate"
    ara_hunter = "ara_hunter"


class AnalysisResult(BaseModel):
    symbol: str
    market: Market
    signal: str = "HOLD"  # BUY / HOLD / SELL
    score: float = Field(ge=0, le=100)
    summary: str = ""
    highlights: List[str] = []
    generated_at: str  # ISO-8601


class WeeklyPrediction(BaseModel):
    symbol: str
    direction: str = "FLAT"  # UP / DOWN / FLAT
    expected_change_percent: float = 0.0
    confidence: float = Field(ge=0, le=1)
    rationale: str = ""


class ScreenerMatch(BaseModel):
    symbol: str
    name: str = ""
    score: float
    signal: str = "HOLD"
    price: float
    change_percent: float
    categories: List[ScreenerCategory] = []


class ScreenerResult(BaseModel):
    market: Market
    matches: List[ScreenerMatch] = []
    generated_at: str  # ISO-8601
    # Pagination/filter metadata (added for "showing N of M" + load-more).
    total_count: int = 0  # matches after filtering, BEFORE the limit
    returned_count: int = 0  # matches actually returned (== len(matches))
    limit: int = 50
    min_score: float = 0.0
    categories: List[ScreenerCategory] = []


class HealthResponse(BaseModel):
    status: str = "ok"
    service: str = "tradewiz-backend"
    version: str
