"""Pydantic models for Portfolio Rebalancing AI."""

from __future__ import annotations

from typing import List

from pydantic import BaseModel

from ..models import Market

# Risk profiles -> max single-position weight (% of equity).
PROFILE_CONSERVATIVE = "Conservative"
PROFILE_BALANCED = "Balanced"
PROFILE_AGGRESSIVE = "Aggressive"

# Actions.
ACTION_ADD = "ADD"
ACTION_HOLD = "HOLD"
ACTION_REDUCE = "REDUCE"
ACTION_EXIT = "EXIT"

# Priorities.
PRIORITY_HIGH = "HIGH"
PRIORITY_MEDIUM = "MEDIUM"
PRIORITY_LOW = "LOW"


class RebalanceAction(BaseModel):
    symbol: str
    market: Market
    name: str = ""
    action: str = ACTION_HOLD
    reason: str = ""
    current_weight: float = 0.0
    target_weight: float = 0.0
    priority: str = PRIORITY_LOW
    score: float = 0.0
    quality_score: float = 0.0
    # Unrealized P/L for the held position (drives the take-profit trim and
    # the app's profit display). pnl_pct is the % return on cost basis;
    # pnl_value is the absolute gain/loss in account currency.
    pnl_pct: float = 0.0
    pnl_value: float = 0.0


class RebalanceResponse(BaseModel):
    user_id: int
    generated_at: str = ""
    profile: str = PROFILE_BALANCED
    portfolio_score: float = 0.0
    cash_allocation: float = 0.0
    actions: List[RebalanceAction] = []
    summary: str = ""
    warnings: List[str] = []
    high_priority_count: int = 0
    estimated_score_improvement: float = 0.0
    simulated: bool = True
