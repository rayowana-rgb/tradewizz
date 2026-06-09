"""Pydantic models for Portfolio Health + Position Quality (Elite)."""

from __future__ import annotations

from typing import Dict, List

from pydantic import BaseModel

from ..models import Market


class HealthComponents(BaseModel):
    diversification: float = 0.0     # 0..100
    concentration_risk: float = 0.0  # 0..100 (higher = healthier / less risk)
    liquidity: float = 0.0           # 0..100
    quality: float = 0.0             # 0..100 (avg position quality)
    sector_exposure: float = 0.0     # 0..100 (market/sector balance)


class PositionQuality(BaseModel):
    symbol: str
    market: Market
    quantity: float = 0.0
    quality_score: float = 0.0  # 0..100
    # Components (0..100):
    trend: float = 0.0
    relative_strength: float = 0.0
    momentum: float = 0.0
    volume: float = 0.0
    risk: float = 0.0           # higher = safer
    rating: str = ""            # Strong / Solid / Weak
    note: str = ""


class PortfolioHealth(BaseModel):
    user_id: int
    generated_at: str
    health_score: float = 0.0   # 0..100
    rating: str = ""            # Excellent / Good / Fair / Poor
    components: HealthComponents
    warnings: List[str] = []
    strengths: List[str] = []
    exit_warnings: List[str] = []
    market_exposure: Dict[str, float] = {}  # market -> % of equity
    positions: List[PositionQuality] = []
    simulated: bool = True


class PositionQualityResponse(BaseModel):
    user_id: int
    generated_at: str
    positions: List[PositionQuality] = []
    simulated: bool = True
