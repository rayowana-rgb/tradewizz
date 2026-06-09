"""Pydantic models for the AI Morning Brief."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..models import Market


class BriefPick(BaseModel):
    """A single highlighted name in the brief (top opportunity / multibagger)."""

    symbol: str
    market: Market
    name: str = ""
    score: float = 0.0
    signal: str = "HOLD"
    reason: str = ""


class MorningBrief(BaseModel):
    """A rule-based, once-per-session summary for one market."""

    market: Market
    title: str = "AI Morning Brief"
    generated_at: str = ""          # ISO-8601 (UTC)
    session_date: str = ""          # YYYY-MM-DD (UTC) — the cache key
    market_regime: str = "NEUTRAL"  # BULL / NEUTRAL / BEAR
    strongest_sector: str = ""      # rule-based sector label
    headline: str = ""              # one-line summary
    top_opportunity: Optional[BriefPick] = None
    top_multibagger: Optional[BriefPick] = None
    notes: List[str] = []
    simulated: bool = False         # research only; no positions involved
    cached: bool = False            # True when served from the daily cache
    # --- Trading-date-aware freshness (display-only when stale) ---
    stale: bool = False             # True when data is older than fresh policy
    fallback: bool = False          # True when served as a fallback
    freshness: str = "live"         # live|last_close|previous_close|stale|unavailable
    data_available: bool = True     # False -> partial-unavailable response
