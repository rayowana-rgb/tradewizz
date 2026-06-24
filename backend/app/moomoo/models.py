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
