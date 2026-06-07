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


class EquityPoint(BaseModel):
    timestamp: str
    total_equity: float


class BrokerBreakdown(BaseModel):
    broker: str
    equity: float = 0.0
    cash: float = 0.0
    market_value: float = 0.0
    floating_pnl: float = 0.0


class AssetBreakdown(BaseModel):
    # Grouping key: a market code (HKEX/US/KOSPI/KOSDAQ/IDX) or 'Cash'.
    asset: str
    market_value: float = 0.0
    floating_pnl: float = 0.0


class PositionPnL(BaseModel):
    symbol: str
    broker: str
    unrealized_pnl: float = 0.0
    unrealized_pnl_percent: float = 0.0


class PortfolioPerformance(BaseModel):
    total_equity: float = 0.0
    cash: float = 0.0
    market_value: float = 0.0
    floating_pnl: float = 0.0
    realized_pnl: float = 0.0
    total_pnl: float = 0.0
    daily_pnl: float = 0.0
    daily_pnl_percent: float = 0.0
    equity_curve: List[EquityPoint] = []
    broker_breakdown: List[BrokerBreakdown] = []
    asset_breakdown: List[AssetBreakdown] = []
    top_winners: List[PositionPnL] = []
    top_losers: List[PositionPnL] = []
    # Non-fatal notes (e.g. realized P/L unavailable for a broker).
    notes: List[str] = []
    errors: List[BrokerError] = []


class PortfolioSnapshot(BaseModel):
    id: int
    user_id: int
    timestamp: str
    total_equity: float
    cash: float
    market_value: float
    floating_pnl: float
    realized_pnl: float


class UnifiedPortfolio(BaseModel):
    summary: PortfolioSummary
    positions: List[PortfolioPosition] = []
    # Brokers that contributed to this aggregate.
    brokers: List[str] = []
    # Non-fatal per-broker errors (e.g. OpenD down, IBKR stub) so the rest of
    # the portfolio still aggregates.
    errors: List[BrokerError] = []
