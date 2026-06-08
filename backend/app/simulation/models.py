"""Pydantic models for the simulated paper-trading portfolio.

All responses carry ``simulated=true`` and a disclaimer so the UI can never
imply a real broker order. Wording intentionally avoids "real order", "live
trade", "order sent to broker", "IBKR order submitted".
"""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field

from ..models import Market

# Single source of truth for the disclaimer copy.
SIM_WARNING = "Simulation only. No real broker order will be sent."
SIM_DISCLAIMER = "This is a simulated portfolio. No real broker order is sent."
SIM_FILL_MESSAGE = "Simulated order filled. No real broker order was sent."
STATUS_FILLED = "FILLED_SIMULATED"


class OrderSide:
    BUY = "BUY"
    SELL = "SELL"


class OrderType:
    MARKET = "MARKET"
    LIMIT = "LIMIT"


class SimulatedPosition(BaseModel):
    user_id: int
    symbol: str
    market: Market
    quantity: float = 0.0
    average_cost: float = 0.0
    last_price: float = 0.0
    market_value: float = 0.0
    unrealized_pnl: float = 0.0
    realized_pnl: float = 0.0
    created_at: str = ""
    updated_at: str = ""


class SimulatedAccount(BaseModel):
    user_id: int
    cash: float = 0.0
    equity: float = 0.0          # cash + market value
    buying_power: float = 0.0    # == cash for an unleveraged sim
    market_value: float = 0.0
    unrealized_pnl: float = 0.0
    realized_pnl: float = 0.0
    currency: str = "USD"
    created_at: str = ""
    updated_at: str = ""
    simulated: bool = True
    disclaimer: str = SIM_DISCLAIMER


class SimulatedTrade(BaseModel):
    id: int
    user_id: int
    order_id: str
    symbol: str
    market: Market
    side: str            # BUY / SELL
    quantity: float
    price: float
    value: float         # quantity * price
    realized_pnl: float = 0.0   # realized on this trade (SELL only)
    created_at: str = ""
    simulated: bool = True


class SimulatedPortfolioSummary(BaseModel):
    account: SimulatedAccount
    positions: List[SimulatedPosition] = []
    simulated: bool = True
    disclaimer: str = SIM_DISCLAIMER


class SimulatedOrderRequest(BaseModel):
    symbol: str
    market: Market
    side: str = Field(..., description="BUY or SELL")
    quantity: float = Field(gt=0)
    order_type: str = OrderType.MARKET
    price: Optional[float] = Field(default=None, ge=0)


class SimulatedOrderPreview(BaseModel):
    symbol: str
    market: Market
    side: str
    quantity: float
    order_type: str
    price: float                 # the simulated execution price
    estimated_value: float
    currency: str = "USD"
    cash_after: float = 0.0
    simulated: bool = True
    warning: str = SIM_WARNING


class SimulatedOrderResult(BaseModel):
    order_id: str
    symbol: str
    market: Market
    side: str
    quantity: float
    price: float
    value: float = 0.0
    status: str = STATUS_FILLED
    realized_pnl: float = 0.0
    cash_after: float = 0.0
    simulated: bool = True
    message: str = SIM_FILL_MESSAGE


class SimulatedTradeList(BaseModel):
    trades: List[SimulatedTrade] = []
    simulated: bool = True


class SimulatedPositionList(BaseModel):
    positions: List[SimulatedPosition] = []
    simulated: bool = True


class SimulatedResetResult(BaseModel):
    user_id: int
    cash: float
    simulated: bool = True
    message: str = "Simulation portfolio reset. No real broker order was sent."
