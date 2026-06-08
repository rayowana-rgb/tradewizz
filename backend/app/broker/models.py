"""Pydantic models for the broker (Moomoo) endpoints."""

from __future__ import annotations

from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field

from ..models import Market


class OrderSide(str, Enum):
    BUY = "BUY"
    SELL = "SELL"


class OrderType(str, Enum):
    MARKET = "MARKET"
    LIMIT = "LIMIT"


class BrokerStatus(BaseModel):
    connected: bool
    trading_env: str  # PAPER / REAL
    is_real: bool
    host: str
    port: int
    # API client id used to connect (safe, non-secret) — aids diagnosing a
    # status mismatch / 'clientId already in use'.
    client_id: Optional[int] = None
    # Loud warning surfaced to clients when real trading is enabled.
    warning: Optional[str] = None
    message: str = ""


class AccountSummary(BaseModel):
    connected: bool = True
    currency: str = ""
    cash: float = 0.0
    buying_power: float = 0.0
    total_assets: float = 0.0
    trading_env: str = "PAPER"


class Position(BaseModel):
    symbol: str
    market: Market
    quantity: float
    cost_price: float = 0.0
    current_price: float = 0.0
    market_value: float = 0.0
    pl_value: float = 0.0


class PositionsResponse(BaseModel):
    connected: bool = True
    positions: List[Position] = []


class OrderRequest(BaseModel):
    symbol: str
    market: Market
    side: OrderSide
    quantity: float = Field(gt=0)
    order_type: OrderType = OrderType.LIMIT
    price: Optional[float] = Field(default=None, ge=0)


class OrderPreview(BaseModel):
    symbol: str
    market: Market
    moomoo_code: str  # resolved broker symbol (e.g. US.AAPL, HK.00700)
    side: OrderSide
    quantity: float
    order_type: OrderType
    price: Optional[float] = None
    estimated_value: float = 0.0
    currency: str = ""
    trading_env: str = "PAPER"
    is_real: bool = False
    # Token the client must echo back to /order/place to confirm.
    confirmation_token: str
    expires_in_seconds: float = 120.0
    warnings: List[str] = []


class PlaceOrderRequest(OrderRequest):
    confirmation_token: str


class OrderResult(BaseModel):
    order_id: str
    symbol: str
    market: Market
    side: OrderSide
    quantity: float
    order_type: OrderType
    price: Optional[float] = None
    status: str  # SUBMITTED / FILLED / CANCELLED / REJECTED / ...
    trading_env: str = "PAPER"
    is_real: bool = False
    message: str = ""


class OpenOrder(BaseModel):
    order_id: str
    symbol: str
    side: OrderSide
    quantity: float
    order_type: OrderType
    price: Optional[float] = None
    status: str
    created_at: str = ""


class OrdersResponse(BaseModel):
    connected: bool = True
    orders: List[OpenOrder] = []
    # Optional non-fatal note, e.g. IBKR Read-Only API mode blocking order
    # requests. Default None preserves existing Moomoo responses unchanged.
    note: Optional[str] = None


class CancelRequest(BaseModel):
    order_id: str


class CancelResult(BaseModel):
    order_id: str
    cancelled: bool
    status: str = ""
    message: str = ""
