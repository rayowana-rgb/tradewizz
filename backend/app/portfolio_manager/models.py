"""Pydantic models for the AI Portfolio Manager."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..models import Market


class Recommendation(BaseModel):
    """A single rule-based, plain-language portfolio recommendation."""

    kind: str                 # concentration / weak_position / strong_position
                              # / cash_allocation / diversification / health
    severity: str = "info"    # info / warning / critical
    symbol: Optional[str] = None
    market: Optional[Market] = None
    title: str = ""
    message: str = ""


class PortfolioManagerReport(BaseModel):
    user_id: int
    generated_at: str = ""
    risk_level: str = "MODERATE"        # LOW / MODERATE / HIGH
    portfolio_score: float = 0.0        # 0..100 (== health score)
    concentration_score: float = 0.0    # 0..100 (higher = healthier)
    diversification_score: float = 0.0  # 0..100
    quality_score: float = 0.0          # 0..100 (avg position quality)
    cash_pct: float = 0.0               # cash as % of equity
    largest_position_pct: float = 0.0   # biggest single name, % of equity
    recommendations: List[Recommendation] = []
    simulated: bool = True
