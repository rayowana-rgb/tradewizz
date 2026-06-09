"""Pydantic models for the Global Rotation Engine."""

from __future__ import annotations

from typing import List

from pydantic import BaseModel

from ..models import Market

REC_OVERWEIGHT = "OVERWEIGHT"
REC_NEUTRAL = "NEUTRAL"
REC_UNDERWEIGHT = "UNDERWEIGHT"
REC_AVOID = "AVOID"


class MarketRotation(BaseModel):
    market: Market
    rotation_score: float = 0.0
    rank: int = 0
    regime: str = "NEUTRAL"
    top_score_average: float = 0.0
    elite_count: int = 0      # stocks with score >= 90
    strong_count: int = 0     # stocks with score >= 85
    breadth: float = 0.0      # % of scanned names advancing
    liquidity: float = 0.0    # median turnover proxy (0..100)
    volatility: float = 0.0   # dispersion proxy (0..100)
    recommendation: str = REC_NEUTRAL


class GlobalRotationResponse(BaseModel):
    generated_at: str = ""
    session_date: str = ""
    best_market: str = ""
    rotation_summary: str = ""
    markets: List[MarketRotation] = []
    simulated: bool = True
    cached: bool = False        # True when served from the rotation TTL cache
