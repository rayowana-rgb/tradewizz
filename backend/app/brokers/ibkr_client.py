"""IBKR client over ib_insync (IB Gateway / TWS).

- Lazy ib_insync import (absence is non-fatal).
- ib_insync performs the API handshake directly (NO raw-socket pre-flight).
  Opening a bare TCP socket and closing it before the API version is sent
  made IB Gateway log 'Client disconnected before version was sent / API
  client version is missing' and could race the clientId on the order path,
  surfacing as a generic 502. We now rely solely on ib_insync.connect with a
  bounded timeout, which does the real handshake.
- Returns plain dicts; the adapter maps them to the shared broker models.
- `MockIBKRClient` for tests / paper demos: in-memory, never contacts a venue.
"""

from __future__ import annotations

import asyncio
import itertools
import logging
import os
import threading
import time
import traceback
from typing import Dict, List, Optional

from .ibkr_config import IBKRConfig

logger = logging.getLogger("tradewizz.ibkr")

# --------------------------------------------------------------------------- #
# Process-wide IBKR gateway lock (the clientId-race fix).                      #
#                                                                              #
# IB Gateway/TWS allows only ONE live API connection per clientId. A single   #
# API request opens several SEQUENTIAL ib_insync connections on the SAME       #
# clientId (status=1; portfolio=account+positions=2; order=1), and a          #
# disconnect does NOT instantly free the clientId at the gateway. With        #
# concurrent requests (or rapid back-to-back connects) the next connect       #
# arrives while the gateway still considers the clientId in use -> IB error   #
# 326 'client id is already in use' -> surfaced as 'IB Gateway not reachable'. #
# Using a brand-new clientId sidesteps the lingering one (why client_id 33    #
# 'worked'). We instead SERIALIZE every connect->use->disconnect with one     #
# process-wide lock so connects never overlap, and RETRY briefly on a         #
# transient clientId-in-use while the previous socket finishes closing. This  #
# is deterministic and keeps a single stable clientId.                        #
# --------------------------------------------------------------------------- #
_GATEWAY_LOCK = threading.RLock()

# Retry tuning for a transient 'client id already in use' right after a prior
# disconnect on the same clientId. Bounded so a genuinely-taken clientId still
# fails fast with a clear error.
_CLIENT_ID_RETRIES = 3
_CLIENT_ID_BACKOFF = 0.4  # seconds between retries


def _ensure_event_loop() -> asyncio.AbstractEventLoop:
    """Guarantee the current thread has an asyncio event loop.

    ib_insync (via eventkit) calls ``asyncio.get_event_loop()`` both at import
    time and during use. Under FastAPI a sync route runs in an AnyIO worker
    thread that has NO event loop, so get_event_loop() raises::

        RuntimeError: There is no current event loop in thread
                      'AnyIO worker thread'

    which previously surfaced as an Internal Server Error on order/place.
    Creating and setting a fresh loop for the worker thread makes ib_insync
    import and operate normally. Safe to call repeatedly (idempotent per
    thread); the main-thread path keeps its existing loop.
    """
    try:
        return asyncio.get_event_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        logger.debug(
            "created asyncio event loop for thread without one "
            "(ib_insync requires it)"
        )
        return loop


def _import_ib_insync():
    """Import ib_insync after ensuring an event loop exists in this thread.

    Both the import and the subsequent IB() usage need a current event loop;
    ensure one first so worker-thread requests never hit
    'no current event loop'.
    """
    _ensure_event_loop()
    import ib_insync  # noqa: F401

    return ib_insync


class IBKRError(Exception):
    """IBKR failure surfaced cleanly (gateway down, SDK missing, etc.)."""


class IBKRConnectionError(IBKRError):
    """IB Gateway/TWS could not be reached or the connect timed out.

    Carries a clear reason (timeout, refused, etc.) so the API returns a
    specific 502 instead of a generic 'not reachable'.
    """


class IBKRClientIdInUseError(IBKRError):
    """The configured clientId is already in use by another API connection.

    IB error 326 == 'Unable to connect as the client id is already in use'.
    """


class IBKRReadOnlyError(IBKRError):
    """Order request blocked by IB Gateway Read-Only API mode (Error 321).

    This is NOT a disconnect: account summary and positions still work. The
    service treats it as connected=true with empty orders + a note.
    """


class IBKRInsufficientFundsError(IBKRError):
    """Order rejected for insufficient buying power / margin (IB error 201)."""


# IB error 201 == 'Order rejected - reason: ... insufficient ... margin'.
_INSUFFICIENT_HINTS = (
    "insufficient", "buying power", "margin", "error 201", " 201",
)


def _looks_insufficient(text: str) -> bool:
    t = text.lower()
    return any(h in t for h in _INSUFFICIENT_HINTS)


# IB error 321 == 'The API interface is currently in Read-Only mode.'
_READ_ONLY_HINTS = ("read-only", "readonly", "error 321", " 321")


def _looks_read_only(exc: Exception) -> bool:
    msg = str(exc).lower()
    return any(h in msg for h in _READ_ONLY_HINTS)


# IB error 326 == 'Unable to connect as the client id is already in use'.
_CLIENT_ID_HINTS = ("client id is already in use", "clientid", "error 326",
                    " 326")


def _looks_client_id_in_use(exc: Exception) -> bool:
    msg = str(exc).lower()
    return any(h in msg for h in _CLIENT_ID_HINTS)


_TIMEOUT_HINTS = ("timeout", "timed out", "refused", "unreachable",
                  "connection reset", "no route")


def _looks_timeout(exc: Exception) -> bool:
    msg = str(exc).lower()
    return isinstance(exc, (TimeoutError, ConnectionError)) or any(
        h in msg for h in _TIMEOUT_HINTS
    )


def _classify_connect_error(exc: Exception) -> IBKRError:
    """Map a raw ib_insync connect failure to a specific IBKR error.

    Order of precedence: clientId-in-use > read-only > timeout/unreachable.
    """
    if _looks_client_id_in_use(exc):
        return IBKRClientIdInUseError(
            "IB Gateway clientId is already in use by another connection. "
            "Close the other session or change TRADEWIZZ_IBKR_CLIENT_ID."
        )
    if _looks_read_only(exc):
        return IBKRReadOnlyError(str(exc))
    if _looks_timeout(exc):
        return IBKRConnectionError(
            f"IB Gateway connection timed out / refused: {exc}"
        )
    return IBKRConnectionError(f"IB Gateway connect failed: {exc}")


class IBKRClient:
    """Talks to IB Gateway/TWS. Connects per-call under a process-wide lock.

    Every connect->use->disconnect runs while holding ``_GATEWAY_LOCK`` so two
    requests never race the same clientId. No long-lived connection is held
    between requests; we connect, do the work, and disconnect every call.
    """

    def __init__(self, config: IBKRConfig):
        self._config = config
        logger.info(
            "IBKRClient created %s id=%s",
            self._diag("client-init"), hex(id(self)),
        )

    # -- diagnostics -----------------------------------------------------

    def _diag(self, source: str) -> str:
        """One-line connection diagnostics (req 2): which path, target, ids."""
        cfg = self._config
        return (
            f"source={source} host={cfg.host} port={cfg.port} "
            f"client_id={cfg.client_id} env={cfg.trading_env_label} "
            f"pid={os.getpid()} thread={threading.current_thread().name} "
            f"client_obj=0x{id(self):x}"
        )

    # -- connection ------------------------------------------------------

    def _do_connect(self, ib, readonly: bool, source: str):
        """ib_insync.connect with a bounded clientId-in-use retry, serialized
        by the caller under _GATEWAY_LOCK."""
        cfg = self._config
        last: Optional[Exception] = None
        for attempt in range(1, _CLIENT_ID_RETRIES + 1):
            try:
                logger.info(
                    "ibkr connect attempt=%d/%d readonly=%s %s",
                    attempt, _CLIENT_ID_RETRIES, readonly, self._diag(source),
                )
                ib.connect(
                    cfg.host, cfg.port, clientId=cfg.client_id,
                    timeout=cfg.connect_timeout, readonly=readonly,
                )
                logger.info("ibkr connect ok %s", self._diag(source))
                return
            except Exception as exc:  # noqa: BLE001
                # ib_insync raises if the post-handshake sync times out even
                # though the API socket is connected; the caller checks
                # isConnected() and keeps it. Re-raise to let it decide.
                if ib.isConnected():
                    raise
                last = exc
                if _looks_client_id_in_use(exc) and \
                        attempt < _CLIENT_ID_RETRIES:
                    logger.warning(
                        "ibkr clientId busy, retrying in %.2fs %s",
                        _CLIENT_ID_BACKOFF, self._diag(source),
                    )
                    self._safe_disconnect(ib)
                    time.sleep(_CLIENT_ID_BACKOFF)
                    continue
                raise
        if last is not None:
            raise last

    def _connect(self):
        """Connect for READ paths (account/positions).

        We always connect ``readonly=True`` here so ib_insync skips the
        open/completed-orders sync during connect. We also tolerate the
        post-handshake execution-sync timing out (it can in Read-Only API
        mode): as long as the API socket is actually connected, the
        connection is usable for account summary and positions. This is the
        fix for 'IBKR is not reachable' when the gateway is Read-Only.

        No raw-socket pre-flight: ib_insync.connect performs the API handshake
        with a bounded timeout. (A bare socket probe made IB Gateway log
        'client disconnected before version was sent'.)
        """
        return self._connect_impl(readonly=True, source="read")

    def _connect_impl(self, readonly: bool, source: str):
        """Shared connect body for read/order paths. Caller already holds the
        gateway lock (via account_summary/positions/place_order/etc.)."""
        try:
            IB = _import_ib_insync().IB
        except Exception as exc:  # noqa: BLE001
            raise IBKRError(f"ib_insync unavailable: {exc}") from exc
        ib = IB()
        try:
            self._do_connect(ib, readonly=readonly, source=source)
        except Exception as exc:  # noqa: BLE001
            # ib_insync raises if the post-handshake sync (e.g. executions)
            # times out, even though the API socket is connected and account
            # summary works. Keep the connection if the socket is live.
            if ib.isConnected():
                logger.warning(
                    "IBKR connect sync incomplete (%s); socket is connected, "
                    "continuing. %s", exc, self._diag(source),
                )
                return ib
            self._safe_disconnect(ib)
            raise _classify_connect_error(exc) from exc
        return ib

    def _connect_for_orders(self):
        """Connect for ORDER paths (place/cancel/orders).

        Uses the configured trading mode: real -> readonly=False (orders
        allowed), paper -> readonly=True. Order-write attempts in Read-Only
        API mode are surfaced as IBKRReadOnlyError, not a disconnect.

        No raw-socket pre-flight here either: the bare-socket close before the
        API handshake is exactly what produced the 502 on the order path.
        """
        return self._connect_impl(
            readonly=not self._config.is_real, source="order"
        )

    def is_connected(self) -> bool:
        """True if the API socket connects (Read-Only mode counts as connected).

        Uses the read-path connect, which tolerates order/execution-sync
        timeouts, so Read-Only API mode is reported as connected. No raw-socket
        probe: ib_insync.connect (bounded timeout) is the single source of
        truth for reachability.
        """
        with _GATEWAY_LOCK:
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
        with _GATEWAY_LOCK:
            return self._account_summary_locked()

    def _account_summary_locked(self) -> dict:
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
        with _GATEWAY_LOCK:
            return self._positions_locked()

    def _positions_locked(self) -> List[dict]:
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
        with _GATEWAY_LOCK:
            return self._orders_locked()

    def _orders_locked(self) -> List[dict]:
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
        # Ensure an event loop exists BEFORE importing ib_insync: under FastAPI
        # this runs in an AnyIO worker thread with no loop, and the bare
        # `from ib_insync import ...` triggers eventkit's get_event_loop(),
        # raising 'no current event loop' -> Internal Server Error.
        try:
            ib_insync = _import_ib_insync()
        except Exception as exc:  # noqa: BLE001
            raise IBKRError(f"ib_insync unavailable: {exc}") from exc
        LimitOrder = ib_insync.LimitOrder
        MarketOrder = ib_insync.MarketOrder
        Stock = ib_insync.Stock

        with _GATEWAY_LOCK:
            return self._place_order_locked(
                ib_insync, LimitOrder, MarketOrder, Stock,
                spec, side, quantity, order_type, price,
            )

    def _place_order_locked(self, ib_insync, LimitOrder, MarketOrder, Stock,
                            spec, side, quantity, order_type, price) -> dict:
        cfg = self._config
        # Full per-attempt context so any failure is fully diagnosable from the
        # logs (symbol/market/side/qty/type/price/clientId/host/port).
        ctx = (
            f"symbol={spec.get('symbol')} exchange={spec.get('exchange')} "
            f"currency={spec.get('currency')} side={side} qty={quantity} "
            f"type={order_type} price={price} clientId={cfg.client_id} "
            f"host={cfg.host} port={cfg.port} env={cfg.trading_env_label}"
        )
        logger.info("ibkr place_order start %s", ctx)
        try:
            ib = self._connect_for_orders()
        except IBKRError as exc:
            # Already-classified connect failure (timeout / clientId /
            # read-only / SDK missing). Log full context + traceback, then
            # re-raise the specific error so the API returns a clear reason
            # (not a generic 502 'not reachable').
            logger.error(
                "ibkr place_order connect-failed %s err_type=%s err=%s\n%s",
                ctx, type(exc).__name__, exc, traceback.format_exc(),
            )
            raise
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
            status = str(trade.orderStatus.status) or "SUBMITTED"
            # Detect a broker rejection and surface the reason clearly instead
            # of returning a generic 'submitted'. ib_insync exposes the reason
            # on the order status / log.
            reason = " ".join(
                str(getattr(e, "errorMsg", "") or getattr(e, "message", ""))
                for e in (getattr(trade, "log", []) or [])
            )
            combined = f"{status} {reason}".strip()
            if _looks_read_only(combined):
                raise IBKRReadOnlyError(combined)
            if status.upper() in ("REJECTED", "CANCELLED") and \
                    _looks_insufficient(combined):
                raise IBKRInsufficientFundsError(
                    reason or "Insufficient buying power."
                )
            if status.upper() == "REJECTED":
                raise IBKRError(
                    f"Order rejected by broker: {reason or 'no reason given'}"
                )
            logger.info(
                "ibkr place_order ok %s order_id=%s status=%s",
                ctx, trade.order.orderId, status,
            )
            return {
                "order_id": str(trade.order.orderId),
                "status": status,
            }
        except IBKRError as exc:
            # Read-only / insufficient / broker rejection: log full context +
            # traceback, re-raise the typed error for clear API mapping.
            logger.error(
                "ibkr place_order rejected %s err_type=%s err=%s\n%s",
                ctx, type(exc).__name__, exc, traceback.format_exc(),
            )
            raise
        except Exception as exc:  # noqa: BLE001
            # Unexpected SDK/runtime error: never leak as a generic 502 without
            # a reason — log everything and wrap with the raw type/message.
            logger.error(
                "ibkr place_order error %s err_type=%s err=%s\n%s",
                ctx, type(exc).__name__, exc, traceback.format_exc(),
            )
            raise IBKRError(
                f"Order placement failed ({type(exc).__name__}): {exc}"
            ) from exc
        finally:
            self._safe_disconnect(ib)

    def cancel_order(self, order_id: str) -> dict:
        with _GATEWAY_LOCK:
            return self._cancel_order_locked(order_id)

    def _cancel_order_locked(self, order_id: str) -> dict:
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

    def __init__(self, connected: bool = True, read_only: bool = False,
                 insufficient: bool = False,
                 place_error: Optional[Exception] = None):
        # ``read_only`` simulates IB Gateway Read-Only API mode: account and
        # positions work, but order requests raise IBKRReadOnlyError.
        # ``insufficient`` simulates a buying-power rejection on place.
        # ``place_error`` lets a test inject any exception (e.g. a connection
        # timeout or clientId conflict) raised when place_order connects.
        self._connected = connected
        self._read_only = read_only
        self._insufficient = insufficient
        self._place_error = place_error
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
        if self._place_error is not None:
            raise self._place_error
        if self._read_only:
            raise IBKRReadOnlyError(
                "The API interface is currently in Read-Only mode."
            )
        if getattr(self, "_insufficient", False):
            raise IBKRInsufficientFundsError(
                "Order rejected - insufficient buying power / margin."
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
