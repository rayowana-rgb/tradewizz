"""IBKR client over ib_insync (IB Gateway / TWS).

- Lazy ib_insync import (absence is non-fatal).
- Fast socket pre-flight so a down gateway never hangs (mirrors the Moomoo fix).
- Returns plain dicts; the adapter maps them to the shared broker models.
- `MockIBKRClient` for tests / paper demos: in-memory, never contacts a venue.
"""

from __future__ import annotations

import itertools
import logging
import socket
import time
from typing import Dict, List, Optional

from .ibkr_config import IBKRConfig

logger = logging.getLogger("tradewizz.ibkr")

_PORT_PROBE_TIMEOUT = 1.0


class IBKRError(Exception):
    """IBKR failure surfaced cleanly (gateway down, SDK missing, etc.)."""


class IBKRReadOnlyError(IBKRError):
    """Order request blocked by IB Gateway Read-Only API mode (Error 321).

    This is NOT a disconnect: account summary and positions still work. The
    service treats it as connected=true with empty orders + a note.
    """


# IB error 321 == 'The API interface is currently in Read-Only mode.'
_READ_ONLY_HINTS = ("read-only", "readonly", "error 321", " 321")


def _looks_read_only(exc: Exception) -> bool:
    msg = str(exc).lower()
    return any(h in msg for h in _READ_ONLY_HINTS)


def _port_open(host: str, port: int, timeout: float = _PORT_PROBE_TIMEOUT) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


class IBKRClient:
    """Talks to IB Gateway/TWS. Connects per-call; pre-flight avoids hangs."""

    def __init__(self, config: IBKRConfig):
        self._config = config

    # -- connection ------------------------------------------------------

    def _connect(self):
        """Connect for READ paths (account/positions).

        We always connect ``readonly=True`` here so ib_insync skips the
        open/completed-orders sync during connect. We also tolerate the
        post-handshake execution-sync timing out (it can in Read-Only API
        mode): as long as the API socket is actually connected, the
        connection is usable for account summary and positions. This is the
        fix for 'IBKR is not reachable' when the gateway is Read-Only.
        """
        if not _port_open(self._config.host, self._config.port):
            raise IBKRError(
                f"IB Gateway not reachable at "
                f"{self._config.host}:{self._config.port}"
            )
        try:
            from ib_insync import IB
        except Exception as exc:  # noqa: BLE001
            raise IBKRError(f"ib_insync unavailable: {exc}") from exc
        ib = IB()
        try:
            ib.connect(
                self._config.host,
                self._config.port,
                clientId=self._config.client_id,
                timeout=self._config.connect_timeout,
                # Read paths never need order writes; readonly=True also makes
                # ib_insync skip the open/completed-orders sync on connect.
                readonly=True,
            )
        except Exception as exc:  # noqa: BLE001
            # ib_insync raises if the post-handshake sync (e.g. executions)
            # times out, even though the API socket is connected and account
            # summary works. Keep the connection if the socket is live.
            if ib.isConnected():
                logger.warning(
                    "IBKR connect sync incomplete (%s); socket is connected, "
                    "continuing for account/positions.", exc,
                )
                return ib
            self._safe_disconnect(ib)
            raise IBKRError(f"IB Gateway connect failed: {exc}") from exc
        return ib

    def _connect_for_orders(self):
        """Connect for ORDER paths (place/cancel/orders).

        Uses the configured trading mode: real -> readonly=False (orders
        allowed), paper -> readonly=True. Order-write attempts in Read-Only
        API mode are surfaced as IBKRReadOnlyError, not a disconnect.
        """
        if not _port_open(self._config.host, self._config.port):
            raise IBKRError(
                f"IB Gateway not reachable at "
                f"{self._config.host}:{self._config.port}"
            )
        try:
            from ib_insync import IB
        except Exception as exc:  # noqa: BLE001
            raise IBKRError(f"ib_insync unavailable: {exc}") from exc
        ib = IB()
        try:
            ib.connect(
                self._config.host,
                self._config.port,
                clientId=self._config.client_id,
                timeout=self._config.connect_timeout,
                readonly=not self._config.is_real,
            )
        except Exception as exc:  # noqa: BLE001
            if ib.isConnected():
                return ib
            self._safe_disconnect(ib)
            if _looks_read_only(exc):
                raise IBKRReadOnlyError(str(exc)) from exc
            raise IBKRError(f"IB Gateway connect failed: {exc}") from exc
        return ib

    def is_connected(self) -> bool:
        """True if the API socket connects (Read-Only mode counts as connected).

        Uses the read-path connect, which tolerates order/execution-sync
        timeouts, so Read-Only API mode is reported as connected.
        """
        if not _port_open(self._config.host, self._config.port):
            return False
        try:
            ib = self._connect()
        except IBKRError:
            return False
        try:
            return ib.isConnected()
        except Exception:  # noqa: BLE001
            return False
        finally:
            self._safe_disconnect(ib)

    @staticmethod
    def _safe_disconnect(ib) -> None:
        try:
            ib.disconnect()
        except Exception:  # noqa: BLE001
            pass

    def _acc(self, ib) -> str:
        if self._config.account:
            return self._config.account
        try:
            accts = ib.managedAccounts()
            return accts[0] if accts else ""
        except Exception:  # noqa: BLE001
            return ""

    # -- queries ---------------------------------------------------------

    def account_summary(self) -> dict:
        ib = self._connect()
        try:
            acct = self._acc(ib)
            rows = ib.accountSummary(acct) if acct else ib.accountSummary()
            tags = {r.tag: r.value for r in rows}
            cur = next(
                (r.currency for r in rows if r.tag == "NetLiquidation"), "USD"
            )
            return {
                "currency": cur or "USD",
                "cash": float(tags.get("TotalCashValue", 0) or 0),
                "buying_power": float(tags.get("BuyingPower", 0) or 0),
                "total_assets": float(tags.get("NetLiquidation", 0) or 0),
            }
        finally:
            self._safe_disconnect(ib)

    def positions(self) -> List[dict]:
        ib = self._connect()
        try:
            out = []
            for p in ib.positions(self._acc(ib)) or ib.positions():
                c = p.contract
                out.append({
                    "symbol": getattr(c, "symbol", ""),
                    "exchange": getattr(c, "exchange", "")
                    or getattr(c, "primaryExchange", ""),
                    "currency": getattr(c, "currency", ""),
                    "quantity": float(p.position or 0),
                    "cost_price": float(p.avgCost or 0),
                })
            return out
        finally:
            self._safe_disconnect(ib)

    def orders(self) -> List[dict]:
        """Open orders. In Read-Only API mode order requests are blocked; we
        raise IBKRReadOnlyError so the service reports connected + empty + note
        rather than marking the whole broker disconnected."""
        ib = self._connect_for_orders()
        try:
            try:
                trades = ib.reqOpenOrders()
            except Exception as exc:  # noqa: BLE001
                if _looks_read_only(exc):
                    raise IBKRReadOnlyError(str(exc)) from exc
                raise IBKRError(f"open orders request failed: {exc}") from exc
            out = []
            for t in trades or ib.openTrades():
                o, c = t.order, t.contract
                out.append({
                    "order_id": str(o.orderId),
                    "symbol": getattr(c, "symbol", ""),
                    "side": str(o.action),  # BUY / SELL
                    "quantity": float(o.totalQuantity or 0),
                    "order_type": str(o.orderType),  # MKT / LMT
                    "price": float(o.lmtPrice or 0),
                    "status": str(t.orderStatus.status),
                })
            return out
        finally:
            self._safe_disconnect(ib)

    def place_order(self, spec: dict, side: str, quantity: float,
                    order_type: str, price: Optional[float]) -> dict:
        from ib_insync import LimitOrder, MarketOrder, Stock

        ib = self._connect_for_orders()
        try:
            contract = Stock(spec["symbol"], spec["exchange"], spec["currency"])
            ib.qualifyContracts(contract)
            action = "BUY" if side == "BUY" else "SELL"
            if order_type == "MARKET":
                order = MarketOrder(action, quantity)
            else:
                order = LimitOrder(action, quantity, price or 0)
            trade = ib.placeOrder(contract, order)
            ib.sleep(0.2)
            return {
                "order_id": str(trade.order.orderId),
                "status": str(trade.orderStatus.status) or "SUBMITTED",
            }
        finally:
            self._safe_disconnect(ib)

    def cancel_order(self, order_id: str) -> dict:
        ib = self._connect_for_orders()
        try:
            for t in ib.openTrades():
                if str(t.order.orderId) == str(order_id):
                    ib.cancelOrder(t.order)
                    return {"order_id": order_id, "cancelled": True,
                            "status": "CANCELLED"}
            raise IBKRError(f"Unknown order id: {order_id}")
        finally:
            self._safe_disconnect(ib)


class MockIBKRClient:
    """In-memory IBKR client for tests / paper demo. Never contacts a venue."""

    def __init__(self, connected: bool = True, read_only: bool = False):
        # ``read_only`` simulates IB Gateway Read-Only API mode: account and
        # positions work, but order requests raise IBKRReadOnlyError.
        self._connected = connected
        self._read_only = read_only
        self._orders: Dict[str, dict] = {}
        self._ids = itertools.count(1)

    def is_connected(self) -> bool:
        # Read-Only mode is still 'connected' — account/positions work.
        return self._connected

    def account_summary(self) -> dict:
        if not self._connected:
            raise IBKRError("IB Gateway not reachable")
        return {
            "currency": "USD",
            "cash": 50_000.0,
            "buying_power": 100_000.0,
            "total_assets": 75_000.0,
        }

    def positions(self) -> List[dict]:
        if not self._connected:
            raise IBKRError("IB Gateway not reachable")
        return [{
            "symbol": "AAPL",
            "exchange": "SMART",
            "currency": "USD",
            "quantity": 10.0,
            "cost_price": 180.0,
        }]

    def orders(self) -> List[dict]:
        if self._read_only:
            raise IBKRReadOnlyError(
                "The API interface is currently in Read-Only mode."
            )
        return list(self._orders.values())

    def place_order(self, spec, side, quantity, order_type, price) -> dict:
        if self._read_only:
            raise IBKRReadOnlyError(
                "The API interface is currently in Read-Only mode."
            )
        oid = f"IBKR-{next(self._ids)}"
        self._orders[oid] = {
            "order_id": oid, "symbol": spec["symbol"], "side": side,
            "quantity": quantity, "order_type": order_type, "price": price,
            "status": "SUBMITTED",
        }
        return {"order_id": oid, "status": "SUBMITTED"}

    def cancel_order(self, order_id: str) -> dict:
        if order_id not in self._orders:
            raise IBKRError(f"Unknown order id: {order_id}")
        self._orders[order_id]["status"] = "CANCELLED"
        return {"order_id": order_id, "cancelled": True, "status": "CANCELLED"}
