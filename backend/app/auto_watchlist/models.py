"""Pydantic models for Auto Watchlist AI."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..models import Market

# Source tag written onto applied suggestions (and surfaced to the client).
SOURCE_AUTO_WATCHLIST_AI = "AUTO_WATCHLIST_AI"

# Where a suggestion came from (for transparency in the UI).
ORIGIN_RADAR = "RADAR"
ORIGIN_DAILY_PICK = "DAILY_PICK"
ORIGIN_MULTIBAGGER = "MULTIBAGGER"


class AutoWatchlistSettings(BaseModel):
    """Per-user Auto Watchlist AI settings (persisted)."""

    enabled: bool = True
    markets: List[Market] = []  # empty => all supported markets
    min_score: float = 85.0
    max_per_day: int = 10
    include_multibagger: bool = True
    include_daily_picks: bool = True


class AutoWatchlistSuggestion(BaseModel):
    symbol: str
    market: Market
    name: str = ""
    score: float = 0.0
    signal: str = "HOLD"
    origin: str = ORIGIN_RADAR
    reason: str = ""
    market_regime: str = "NEUTRAL"
    relative_strength: float = 0.0
    liquidity: float = 0.0
    owned: bool = False  # already an open simulated position


class AutoWatchlistSuggestionsResponse(BaseModel):
    generated_at: str = ""
    session_date: str = ""
    suggestions: List[AutoWatchlistSuggestion] = []
    max_suggestions_per_day: int = 10
    enabled: bool = True
    simulated: bool = True


class ApplyItem(BaseModel):
    symbol: str
    market: Market


class ApplyRequest(BaseModel):
    """Apply selected suggestions (or all of today's when items is empty)."""

    items: Optional[List[ApplyItem]] = None
    # Symbols the client already has on its (client-side) watchlist, so we don't
    # re-apply duplicates. Format: "MARKET:SYMBOL" or just "SYMBOL".
    existing: List[str] = []


class AppliedSuggestion(BaseModel):
    symbol: str
    market: Market
    name: str = ""
    source: str = SOURCE_AUTO_WATCHLIST_AI
    reason: str = ""
    score_at_added: float = 0.0
    market_regime_at_added: str = "NEUTRAL"
    added_at: str = ""


class ApplyResponse(BaseModel):
    applied: List[AppliedSuggestion] = []
    skipped: List[str] = []  # symbols skipped (already present)
    count: int = 0
    simulated: bool = True
