"""Pydantic models that exactly match the TradeWiz Flutter app's JSON contract.

Field names use snake_case to match the Dart `fromJson` parsers
(e.g. `generated_at`, `change_percent`, `expected_change_percent`).
"""

from __future__ import annotations

from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


class Market(str, Enum):
    """Supported market codes (mirrors the Flutter `Market` enum codes)."""

    IDX = "IDX"
    HKEX = "HKEX"
    KOSPI = "KOSPI"
    KOSDAQ = "KOSDAQ"
    # Global market expansion (Excel-backed universes).
    US = "US"
    JAPAN = "JAPAN"
    INDIA = "INDIA"
    VIETNAM = "VIETNAM"
    SINGAPORE = "SINGAPORE"


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


class SupportResistance(BaseModel):
    """Support/resistance levels (rolling min/max)."""

    immediate_support: Optional[float] = None
    immediate_resistance: Optional[float] = None
    major_support: Optional[float] = None
    major_resistance: Optional[float] = None


class AnalysisResult(BaseModel):
    symbol: str
    market: Market
    signal: str = "HOLD"  # BUY / HOLD / SELL
    score: float = Field(ge=0, le=100)
    summary: str = ""
    highlights: List[str] = []
    generated_at: str  # ISO-8601
    # --- Phase 3 (additive, optional; older clients ignore these) ---
    recommendation: str = ""  # human-readable BUY/SELL/HOLD verdict
    buy_reasons: List[str] = []  # confirmation reasons (OBV/CMF/A-D/etc.)
    support_resistance: Optional[SupportResistance] = None
    trailing_stop_percent: Optional[float] = None
    trailing_stop_price: Optional[float] = None
    profit_probability: Optional[float] = None  # 0..1 placeholder (ML later)


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
    # Daily turnover (close * volume) in the market's currency. Additive/
    # backward-compatible; used as the liquidity tiebreaker + filter in ranking.
    value_traded: float = 0.0


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
    # --- Market-close caching metadata (additive, optional) ----------------
    # Heavy screening runs once per market/category after market close; the
    # saved snapshot is reused until the next market-close run. Older clients
    # simply ignore these fields.
    cached: bool = False  # True => served from a saved market-close snapshot
    market_status: Optional[str] = None  # "OPEN" or "CLOSED"
    market_date: Optional[str] = None  # YYYY-MM-DD (market-local) of snapshot
    next_refresh_rule: Optional[str] = None  # human-readable refresh policy
    warning: Optional[str] = None  # e.g. force_refresh denied while open


class BacktestResult(BaseModel):
    """Forward-return backtest of a historical buy-signal rule."""

    symbol: str
    market: Market
    signal_type: str  # momentum / scalping / accumulation
    forward_days: int
    total_signals: int
    total_wins: int
    total_losses: int
    win_rate: float  # fraction 0..1
    average_return: float  # mean forward return (fraction, e.g. 0.012)
    profit_factor: float  # sum(wins) / abs(sum(losses)); inf-safe
    max_drawdown: float  # most negative single-signal return (fraction)
    generated_at: str  # ISO-8601


class HealthResponse(BaseModel):
    status: str = "ok"
    service: str = "tradewiz-backend"
    version: str
