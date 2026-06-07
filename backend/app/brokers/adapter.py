"""Broker adapter abstraction for multi-broker support.

`BrokerAdapter` is the uniform interface every broker implements:
account/positions/orders/preview_order/place_order/cancel_order.

- `MoomooAdapter` delegates to the existing Moomoo `BrokerService` (paper-first,
  preview/confirm safety unchanged).
- `IBKRAdapter` is an architecture-only **stub**: it raises NotImplemented so no
  live IBKR call can happen yet.
"""

from __future__ import annotations

from typing import Protocol

from .models import BrokerType


class BrokerNotImplemented(Exception):
    """Raised by stub adapters (e.g. IBKR) that are not live yet."""


class BrokerAdapter(Protocol):
    broker_type: BrokerType

    def account(self): ...

    def positions(self): ...

    def orders(self): ...

    def preview_order(self, **kwargs): ...

    def place_order(self, **kwargs): ...

    def cancel_order(self, order_id: str): ...


class MoomooAdapter:
    """Adapts the existing Moomoo BrokerService to the BrokerAdapter interface."""

    broker_type = BrokerType.MOOMOO

    def __init__(self, service=None):
        # Lazy import avoids a hard dependency at module import time.
        if service is None:
            from ..broker.service import BrokerService

            service = BrokerService()
        self._service = service

    def account(self):
        return self._service.account()

    def positions(self):
        return self._service.positions()

    def orders(self):
        return self._service.orders()

    def preview_order(self, **kwargs):
        return self._service.preview(**kwargs)

    def place_order(self, **kwargs):
        return self._service.place(**kwargs)

    def cancel_order(self, order_id: str):
        return self._service.cancel(order_id)


class IBKRAdapter:
    """Stub IBKR adapter — architecture only, NOT live.

    Every method raises BrokerNotImplemented so no real IBKR call is made.
    """

    broker_type = BrokerType.IBKR

    _MSG = "IBKR integration is not implemented yet."

    def account(self):
        raise BrokerNotImplemented(self._MSG)

    def positions(self):
        raise BrokerNotImplemented(self._MSG)

    def orders(self):
        raise BrokerNotImplemented(self._MSG)

    def preview_order(self, **kwargs):
        raise BrokerNotImplemented(self._MSG)

    def place_order(self, **kwargs):
        raise BrokerNotImplemented(self._MSG)

    def cancel_order(self, order_id: str):
        raise BrokerNotImplemented(self._MSG)


def make_adapter(broker_type: BrokerType) -> BrokerAdapter:
    """Factory: return the adapter for a broker type."""
    if broker_type is BrokerType.MOOMOO:
        return MoomooAdapter()
    if broker_type is BrokerType.IBKR:
        return IBKRAdapter()
    raise ValueError(f"Unknown broker type: {broker_type}")
