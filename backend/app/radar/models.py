"""Pydantic models for the Opportunity Radar endpoints."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..models import Market


class Opportunity(BaseModel):
    symbol: str
    market: Market
    name: str = ""
    score: float
    signal: str = "HOLD"
    recommendation: str = ""       # plain-language verdict
    opportunity_reason: str = ""   # why it surfaced (score/liquidity/RS/regime)
    # Supporting metrics (from the existing screener output).
    relative_strength: float = 0.0  # 0..100 percentile within the scan
    liquidity: float = 0.0          # value_traded
    change_percent: float = 0.0
    market_regime: str = "NEUTRAL"  # BULL / NEUTRAL / BEAR
    composite_rank_score: float = 0.0  # internal ranking score (0..100)


class OpportunitiesResponse(BaseModel):
    generated_at: str
    global_top10: List[Opportunity] = []
    us_top10: List[Opportunity] = []
    idx_top10: List[Opportunity] = []
    multibagger_candidates: List[Opportunity] = []


class DailyPick(BaseModel):
    rank: int
    symbol: str
    market: Market
    name: str = ""
    score: float
    signal: str = "HOLD"
    recommendation: str = ""


class DailyPicksResponse(BaseModel):
    title: str = "Today's Top Opportunities"
    generated_at: str
    date: str = ""  # YYYY-MM-DD (UTC)
    picks: List[DailyPick] = []


class MultibaggerCandidate(BaseModel):
    symbol: str
    market: Market
    name: str = ""
    score: float
    signal: str = "HOLD"
    conviction: str = "MODERATE"   # SPECULATIVE / MODERATE / HIGH
    risk_level: str = "HIGH"       # LOW / MEDIUM / HIGH
    relative_strength: float = 0.0
    liquidity: float = 0.0
    market_regime: str = "NEUTRAL"
    reason: str = ""


class MultibaggerResponse(BaseModel):
    generated_at: str
    criteria: List[str] = []
    candidates: List[MultibaggerCandidate] = []
