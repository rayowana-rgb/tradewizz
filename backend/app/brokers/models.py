"""Models for the multi-broker connection framework."""

from __future__ import annotations

from enum import Enum
from typing import List, Optional

from pydantic import BaseModel, Field


class BrokerType(str, Enum):
    MOOMOO = "MOOMOO"
    IBKR = "IBKR"


# Brokers that are implemented (can actually connect/trade) vs stubs.
IMPLEMENTED_BROKERS = {BrokerType.MOOMOO}


class BrokerConnection(BaseModel):
    id: int
    user_id: int
    broker_type: BrokerType
    display_name: str
    is_active: bool
    created_at: str


class ConnectBrokerRequest(BaseModel):
    broker_type: BrokerType
    display_name: Optional[str] = Field(default=None, max_length=64)


class BrokerConnectionList(BaseModel):
    connections: List[BrokerConnection] = []


class DisconnectResult(BaseModel):
    id: int
    disconnected: bool
    message: str = ""
