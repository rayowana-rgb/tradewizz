"""Pydantic models for the Portfolio Journal."""

from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel

from ..models import Market


class JournalEntry(BaseModel):
    """One journaled simulated position (buy snapshot + optional sell close)."""

    id: int = 0
    user_id: int
    symbol: str
    market: Market
    # Buy snapshot.
    buy_date: str = ""              # ISO-8601
    buy_price: float = 0.0
    quantity: float = 0.0
    score: float = 0.0             # engine score at purchase
    signal: str = "HOLD"           # BUY / HOLD / SELL at purchase
    radar_rank: Optional[int] = None      # daily-pick rank at purchase (or None)
    portfolio_health: float = 0.0  # portfolio health score at purchase
    # Sell close (None / 0 while open).
    sell_date: Optional[str] = None
    sell_price: Optional[float] = None
    realized_return: Optional[float] = None  # % return on this entry
    status: str = "OPEN"           # OPEN / CLOSED
    simulated: bool = True


class JournalList(BaseModel):
    entries: List[JournalEntry] = []
    simulated: bool = True


class JournalStats(BaseModel):
    user_id: int
    total_trades: int = 0          # closed entries counted as trades
    open_positions: int = 0
    win_rate: float = 0.0          # % of closed trades with positive return
    average_gain: float = 0.0      # avg return of winning trades (%)
    average_loss: float = 0.0      # avg return of losing trades (%)
    best_trade: Optional[JournalEntry] = None
    worst_trade: Optional[JournalEntry] = None
    simulated: bool = True
