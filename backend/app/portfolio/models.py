"""Models for the unified (multi-broker) portfolio."""

from __future__ import annotations

from typing import List

from pydantic import BaseModel

from ..models import Market


class PortfolioSummary(BaseModel):
    total_equity: float = 0.0
    cash: float = 0.0
    buying_power: float = 0.0
    market_value: float = 0.0
    floating_pnl: float = 0.0   # unrealized P/L across positions
    realized_pnl: float = 0.0


class PortfolioPosition(BaseModel):
    symbol: str
    market: Market
    broker: str  # broker type, e.g. MOOMOO
    quantity: float
    average_cost: float = 0.0
    current_price: float = 0.0
    market_value: float = 0.0
    unrealized_pnl: float = 0.0


class BrokerError(BaseModel):
    broker: str
    message: str


class UnifiedPortfolio(BaseModel):
    summary: PortfolioSummary
    positions: List[PortfolioPosition] = []
    # Brokers that contributed to this aggregate.
    brokers: List[str] = []
    # Non-fatal per-broker errors (e.g. OpenD down, IBKR stub) so the rest of
    # the portfolio still aggregates.
    errors: List[BrokerError] = []
