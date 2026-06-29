"""Pydantic models for the private Moomoo live-trading bridge."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel


class MoomooAccountModel(BaseModel):
    total_assets: float
    cash: float
    buying_power: float
    market_value: float
    currency: str = "USD"
    # Cumulative realized profit/loss booked on the account (closed positions).
    realized_pl: float = 0.0
    live: bool = True


class MoomooEquityPoint(BaseModel):
    ts: int          # epoch seconds (UTC)
    equity: float    # total account assets in USD


class MoomooEquityHistory(BaseModel):
    points: List[MoomooEquityPoint] = []
    currency: str = "USD"
    live: bool = True


class MoomooPositionModel(BaseModel):
    code: str
    symbol: str
    quantity: float
    can_sell_qty: float
    cost_price: float
    last_price: float
    pl_val: float
    pl_ratio: float


class MoomooPositionList(BaseModel):
    positions: List[MoomooPositionModel]
    live: bool = True


class MoomooOpenOrderModel(BaseModel):
    order_id: str
    code: str
    symbol: str
    side: str  # BUY | SELL
    quantity: float
    filled_quantity: float = 0.0
    price: float = 0.0
    status: str = ""


class MoomooOpenOrderList(BaseModel):
    orders: List[MoomooOpenOrderModel]
    live: bool = True


class MoomooOrderRequest(BaseModel):
    symbol: str
    side: str  # BUY | SELL
    quantity: float
    order_type: str = "MARKET"  # MARKET | LIMIT
    price: Optional[float] = None
    confirm: bool = False
    # Moomoo trade PIN, supplied per-request for unlock. Never stored.
    trade_pin: Optional[str] = None


class MoomooOrderPreview(BaseModel):
    code: str
    symbol: str
    side: str
    order_type: str
    quantity: float
    price: float
    est_notional: float
    max_notional: float
    within_cap: bool
    live: bool = True
    currency: str = "USD"


class MoomooOrderResultModel(BaseModel):
    order_id: str
    code: str
    side: str
    order_type: str
    quantity: float
    price: float
    status: str
    live: bool = True


class MoomooCancelResult(BaseModel):
    order_id: str
    status: str
    live: bool = True


class MoomooBracketRequest(BaseModel):
    """Attach a server-managed stop-loss / take-profit to a position."""

    symbol: str
    quantity: float
    # Price the levels are derived from (typically the fill / cost price).
    reference_price: float
    # Negative for the stop (below entry), positive for the target. Defaults
    # implement the tight-stop swing plan: -1% stop / +3% target (R:R 1:3).
    stop_pct: float = -1.0
    target_pct: float = 3.0


class MoomooBracketModel(BaseModel):
    symbol: str
    quantity: float
    reference_price: float
    stop_pct: float
    target_pct: float
    stop_price: float
    target_price: float
    status: str
    created_ts: int = 0
    updated_ts: int = 0
    triggered_ts: Optional[int] = None
    triggered_price: Optional[float] = None
    order_id: Optional[str] = None
    note: str = ""


class MoomooBracketList(BaseModel):
    brackets: List[MoomooBracketModel] = []
    live: bool = True


class MoomooManagerRec(BaseModel):
    kind: str
    severity: str
    title: str
    message: str
    symbol: Optional[str] = None


class MoomooManagerReport(BaseModel):
    risk_level: str
    concentration_score: float
    diversification_score: float
    cash_pct: float
    largest_position_pct: float
    holdings_count: int
    recommendations: List[MoomooManagerRec] = []
    live: bool = True
