"""Broker client abstraction.

`BrokerClient` is the interface the service depends on. Two implementations:

- `MoomooBrokerClient`: lazily talks to Moomoo OpenD via the `moomoo` SDK. The
  SDK is imported only when a method is called, so the backend (and tests) run
  fine without OpenD running or the SDK installed.
- `MockBrokerClient`: deterministic in-memory broker for tests / paper demos.
  Never touches the network and never places a real order.
"""

from __future__ import annotations

import itertools
import logging
import time
from typing import Dict, List, Optional, Protocol

from .config import BrokerConfig

logger = logging.getLogger("tradewizz.broker")


class BrokerError(Exception):
    """Broker-layer failure surfaced to the API as a clean error."""


class BrokerClient(Protocol):
    def is_connected(self) -> bool: ...

    def account_summary(self) -> dict: ...

    def positions(self) -> List[dict]: ...

    def place_order(
        self,
        code: str,
        side: str,
        quantity: float,
        order_type: str,
        price: Optional[float],
    ) -> dict: ...

    def list_orders(self) -> List[dict]: ...

    def cancel_order(self, order_id: str) -> dict: ...


# ---------------------------------------------------------------------------
# Mock client (tests + paper demo). Deterministic, in-memory, no network.
# ---------------------------------------------------------------------------


class MockBrokerClient:
    """In-memory broker. Records orders; never contacts a real venue."""

    def __init__(self, connected: bool = True, is_real: bool = False):
        self._connected = connected
        self._is_real = is_real
        self._orders: Dict[str, dict] = {}
        self._ids = itertools.count(1)

    def is_connected(self) -> bool:
        return self._connected

    def account_summary(self) -> dict:
        return {
            "currency": "HKD",
            "cash": 100_000.0,
            "buying_power": 200_000.0,
            "total_assets": 150_000.0,
        }

    def positions(self) -> List[dict]:
        return [
            {
                "code": "HK.00700",
                "quantity": 100.0,
                "cost_price": 380.0,
                "current_price": 412.6,
                "market_value": 41_260.0,
                "pl_value": 3_260.0,
            }
        ]

    def place_order(
        self, code, side, quantity, order_type, price
    ) -> dict:
        oid = f"MOCK-{next(self._ids)}"
        order = {
            "order_id": oid,
            "code": code,
            "side": side,
            "quantity": quantity,
            "order_type": order_type,
            "price": price,
            "status": "SUBMITTED",
            "created_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        }
        self._orders[oid] = order
        return order

    def list_orders(self) -> List[dict]:
        return list(self._orders.values())

    def cancel_order(self, order_id: str) -> dict:
        order = self._orders.get(order_id)
        if not order:
            raise BrokerError(f"Unknown order id: {order_id}")
        order["status"] = "CANCELLED"
        return {"order_id": order_id, "cancelled": True, "status": "CANCELLED"}


# ---------------------------------------------------------------------------
# Real client (Moomoo OpenD). SDK imported lazily so absence is non-fatal.
# ---------------------------------------------------------------------------


class MoomooBrokerClient:
    """Talks to Moomoo OpenD. Connects lazily; SDK import is deferred."""

    def __init__(self, config: BrokerConfig):
        self._config = config

    # -- internals -------------------------------------------------------

    def _trd_env(self):
        from moomoo import TrdEnv

        return TrdEnv.REAL if self._config.is_real else TrdEnv.SIMULATE

    def _context(self):
        """Open a trade context to OpenD (caller closes it)."""
        try:
            from moomoo import OpenSecTradeContext, TrdMarket, SecurityFirm
        except Exception as exc:  # noqa: BLE001
            raise BrokerError(f"Moomoo SDK unavailable: {exc}") from exc
        try:
            return OpenSecTradeContext(
                filter_trdmarket=TrdMarket.HK,
                host=self._config.host,
                port=self._config.port,
                security_firm=SecurityFirm.FUTUSECURITIES,
            )
        except Exception as exc:  # noqa: BLE001
            raise BrokerError(
                f"Cannot reach Moomoo OpenD at "
                f"{self._config.host}:{self._config.port}: {exc}"
            ) from exc

    # -- public ----------------------------------------------------------

    def is_connected(self) -> bool:
        try:
            ctx = self._context()
        except BrokerError:
            return False
        try:
            from moomoo import RET_OK

            ret, _ = ctx.get_acc_list()
            return ret == RET_OK
        except Exception:  # noqa: BLE001
            return False
        finally:
            try:
                ctx.close()
            except Exception:  # noqa: BLE001
                pass

    def account_summary(self) -> dict:
        from moomoo import RET_OK

        ctx = self._context()
        try:
            ret, data = ctx.accinfo_query(
                trd_env=self._trd_env(), acc_id=self._config.acc_id
            )
            if ret != RET_OK:
                raise BrokerError(f"accinfo_query failed: {data}")
            row = data.iloc[0]
            return {
                "currency": str(row.get("currency", "")),
                "cash": float(row.get("cash", 0) or 0),
                "buying_power": float(row.get("power", 0) or 0),
                "total_assets": float(row.get("total_assets", 0) or 0),
            }
        finally:
            ctx.close()

    def positions(self) -> List[dict]:
        from moomoo import RET_OK

        ctx = self._context()
        try:
            ret, data = ctx.position_list_query(
                trd_env=self._trd_env(), acc_id=self._config.acc_id
            )
            if ret != RET_OK:
                raise BrokerError(f"position_list_query failed: {data}")
            out = []
            for _, r in data.iterrows():
                out.append({
                    "code": str(r.get("code", "")),
                    "quantity": float(r.get("qty", 0) or 0),
                    "cost_price": float(r.get("cost_price", 0) or 0),
                    "current_price": float(r.get("nominal_price", 0) or 0),
                    "market_value": float(r.get("market_val", 0) or 0),
                    "pl_value": float(r.get("pl_val", 0) or 0),
                })
            return out
        finally:
            ctx.close()

    def place_order(self, code, side, quantity, order_type, price) -> dict:
        from moomoo import (
            RET_OK, TrdSide, OrderType as MMOrderType,
        )

        ctx = self._context()
        try:
            mm_side = TrdSide.BUY if side == "BUY" else TrdSide.SELL
            mm_type = (
                MMOrderType.MARKET if order_type == "MARKET"
                else MMOrderType.NORMAL
            )
            ret, data = ctx.place_order(
                price=price or 0,
                qty=quantity,
                code=code,
                trd_side=mm_side,
                order_type=mm_type,
                trd_env=self._trd_env(),
                acc_id=self._config.acc_id,
            )
            if ret != RET_OK:
                raise BrokerError(f"place_order failed: {data}")
            row = data.iloc[0]
            return {
                "order_id": str(row.get("order_id", "")),
                "status": str(row.get("order_status", "SUBMITTED")),
            }
        finally:
            ctx.close()

    def list_orders(self) -> List[dict]:
        from moomoo import RET_OK

        ctx = self._context()
        try:
            ret, data = ctx.order_list_query(
                trd_env=self._trd_env(), acc_id=self._config.acc_id
            )
            if ret != RET_OK:
                raise BrokerError(f"order_list_query failed: {data}")
            out = []
            for _, r in data.iterrows():
                out.append({
                    "order_id": str(r.get("order_id", "")),
                    "code": str(r.get("code", "")),
                    "side": str(r.get("trd_side", "")),
                    "quantity": float(r.get("qty", 0) or 0),
                    "order_type": str(r.get("order_type", "")),
                    "price": float(r.get("price", 0) or 0),
                    "status": str(r.get("order_status", "")),
                    "created_at": str(r.get("create_time", "")),
                })
            return out
        finally:
            ctx.close()

    def cancel_order(self, order_id: str) -> dict:
        from moomoo import RET_OK, ModifyOrderOp

        ctx = self._context()
        try:
            ret, data = ctx.modify_order(
                ModifyOrderOp.CANCEL,
                order_id,
                0,
                0,
                trd_env=self._trd_env(),
                acc_id=self._config.acc_id,
            )
            if ret != RET_OK:
                raise BrokerError(f"cancel failed: {data}")
            return {"order_id": order_id, "cancelled": True,
                    "status": "CANCELLED"}
        finally:
            ctx.close()
