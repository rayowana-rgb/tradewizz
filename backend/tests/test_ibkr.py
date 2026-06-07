"""IBKR adapter/service tests (no network; mock IB client)."""

import pytest

from app.broker.models import OrderSide, OrderType
from app.brokers.adapter import IBKRAdapter
from app.brokers.ibkr_client import (
    IBKRClient,
    IBKRClientIdInUseError,
    IBKRConnectionError,
    IBKRError,
    IBKRInsufficientFundsError,
    IBKRReadOnlyError,
    MockIBKRClient,
    _classify_connect_error,
    _ensure_event_loop,
    _import_ib_insync,
)
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKROrderValidationError, IBKRService
from app.brokers.ibkr_symbols import (
    IBKRSymbolNotTradable,
    to_ibkr_contract,
)
from app.models import Market


def _svc(trading_env="paper", connected=True, read_only=False, **cfg):
    return IBKRService(
        config=IBKRConfig(trading_env=trading_env, **cfg),
        client=MockIBKRClient(connected=connected, read_only=read_only),
    )


def _free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# --- symbol mapping ---------------------------------------------------------

def test_us_stock_maps_to_smart_usd():
    for sym in ("AAPL", "MSFT", "NVDA"):
        spec = to_ibkr_contract(sym, None)
        assert spec["exchange"] == "SMART"
        assert spec["currency"] == "USD"
        assert spec["symbol"] == sym


def test_hkex_maps_to_sehk_hkd():
    spec = to_ibkr_contract("700", Market.HKEX)
    assert spec == {
        "symbol": "700", "exchange": "SEHK", "currency": "HKD", "sec_type": "STK"
    }


@pytest.mark.parametrize("market", [Market.IDX, Market.KOSPI, Market.KOSDAQ])
def test_unsupported_markets_not_tradable(market):
    with pytest.raises(IBKRSymbolNotTradable):
        to_ibkr_contract("BBCA", market)


# --- status (gateway down) --------------------------------------------------

def test_status_disconnected_when_gateway_down():
    # Real client against a closed port -> disconnected fast, no hang.
    svc = IBKRService(config=IBKRConfig(port=_free_port()),
                      client=IBKRClient(IBKRConfig(port=_free_port())))
    s = svc.status()
    assert s.connected is False
    assert s.message == "IB Gateway not reachable"


def test_status_paper_no_warning():
    s = _svc("paper").status()
    assert s.trading_env == "PAPER"
    assert s.warning is None


def test_status_real_shows_warning():
    s = _svc("live").status()
    assert s.is_real is True
    assert s.warning and "REAL IBKR TRADING" in s.warning


# --- account / positions (mocked) -------------------------------------------

def test_account_mocked():
    a = _svc().account()
    assert a.connected is True
    assert a.currency == "USD"
    assert a.cash == 50000.0
    assert a.total_assets == 75000.0


def test_positions_mocked():
    pos = _svc().positions()
    assert pos.connected is True
    assert len(pos.positions) == 1
    assert pos.positions[0].symbol == "AAPL"
    assert pos.positions[0].quantity == 10.0


def test_account_disconnected_when_gateway_down():
    a = _svc(connected=False).account()
    assert a.connected is False


# --- order safety -----------------------------------------------------------

def test_preview_does_not_place():
    client = MockIBKRClient()
    svc = IBKRService(config=IBKRConfig(), client=client)
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    assert pv.confirmation_token
    assert pv.trading_env == "PAPER"
    assert client.orders() == []  # nothing placed


def test_place_requires_confirmation_token():
    svc = _svc()
    with pytest.raises(IBKROrderValidationError):
        svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
                  confirmation_token="")


def test_place_with_valid_token_succeeds():
    svc = _svc()
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    res = svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
                    pv.confirmation_token)
    assert res.status == "SUBMITTED"
    assert res.order_id.startswith("IBKR-")


def test_token_for_other_order_rejected():
    svc = _svc()
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    with pytest.raises(IBKROrderValidationError):
        svc.place("AAPL", None, OrderSide.BUY, 20, OrderType.LIMIT, 180.0,
                  pv.confirmation_token)


def test_unsupported_symbol_fails_safely():
    svc = _svc()
    with pytest.raises(IBKROrderValidationError) as ei:
        svc.preview("BBCA", Market.IDX, OrderSide.BUY, 1, OrderType.MARKET, None)
    assert "not tradable via IBKR" in str(ei.value)


def test_duplicate_order_guard():
    clock = {"t": 1000.0}
    svc = IBKRService(
        config=IBKRConfig(duplicate_window_seconds=30,
                          confirmation_ttl_seconds=300),
        client=MockIBKRClient(), clock=lambda: clock["t"],
    )
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
              pv.confirmation_token)
    pv2 = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    with pytest.raises(IBKROrderValidationError):
        svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
                  pv2.confirmation_token)


def test_real_trading_warning_in_preview():
    svc = _svc("live")
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    assert pv.is_real is True
    assert any("REAL IBKR" in w for w in pv.warnings)


# --- order rejections: read-only / insufficient funds -----------------------

def test_place_in_read_only_mode_returns_clear_message():
    svc = IBKRService(
        config=IBKRConfig(),
        client=MockIBKRClient(connected=True, read_only=True),
    )
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    with pytest.raises(IBKROrderValidationError) as ei:
        svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
                  pv.confirmation_token)
    # Exact, actionable message -- never a generic failure.
    assert "Read-Only" in ei.value.message
    assert "Disable Read-Only" in ei.value.message
    assert ei.value.status_code == 409


def test_place_insufficient_funds_returns_clear_message():
    svc = IBKRService(
        config=IBKRConfig(),
        client=MockIBKRClient(connected=True, insufficient=True),
    )
    pv = svc.preview("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0)
    with pytest.raises(IBKROrderValidationError) as ei:
        svc.place("AAPL", None, OrderSide.BUY, 10, OrderType.LIMIT, 180.0,
                  pv.confirmation_token)
    assert "Insufficient buying power" in ei.value.message


def test_mock_client_read_only_blocks_place():
    c = MockIBKRClient(read_only=True)
    with pytest.raises(IBKRReadOnlyError):
        c.place_order({"symbol": "AAPL", "exchange": "SMART",
                       "currency": "USD"}, "BUY", 1, "MARKET", None)


def test_mock_client_insufficient_blocks_place():
    c = MockIBKRClient(insufficient=True)
    with pytest.raises(IBKRInsufficientFundsError):
        c.place_order({"symbol": "AAPL", "exchange": "SMART",
                       "currency": "USD"}, "BUY", 1, "MARKET", None)


# --- adapter wiring ---------------------------------------------------------

def test_adapter_delegates_to_service():
    a = IBKRAdapter(service=_svc())
    assert a.account().currency == "USD"
    assert a.positions().positions[0].symbol == "AAPL"
    assert a.status().connected is True


# --- Read-Only API mode handling --------------------------------------------
# IB Gateway Read-Only API mode: account summary + positions work, but order
# requests are blocked (Error 321). This must NOT mark the broker disconnected.

def test_account_succeeds_in_read_only_mode():
    svc = _svc(read_only=True)
    acc = svc.account()
    assert acc.connected is True
    assert acc.cash == 50_000.0
    assert acc.total_assets == 75_000.0


def test_positions_succeed_in_read_only_mode():
    svc = _svc(read_only=True)
    pos = svc.positions()
    assert pos.connected is True
    assert len(pos.positions) == 1
    assert pos.positions[0].symbol == "AAPL"


def test_orders_read_only_error_does_not_disconnect():
    svc = _svc(read_only=True)
    resp = svc.orders()
    # Still connected, just no orders + an explanatory note.
    assert resp.connected is True
    assert resp.orders == []
    assert resp.note is not None
    assert "Read-Only" in resp.note


def test_status_connected_in_read_only_mode():
    # Read-Only mode is reported as connected (account/positions usable).
    svc = _svc(read_only=True)
    assert svc.status().connected is True


# --- account()/positions() derive connected from the fetch (no redundant
#     is_connected() pre-probe that raced a live gateway) ---------------------

def test_account_connected_without_pre_probe():
    # account() must report connected without calling is_connected() first.
    calls = {"is_connected": 0}
    base = MockIBKRClient()

    class NoProbeClient:
        def is_connected(self):
            calls["is_connected"] += 1
            return base.is_connected()

        def account_summary(self):
            return base.account_summary()

        def positions(self):
            return base.positions()

    svc = IBKRService(config=IBKRConfig(trading_env="paper"),
                      client=NoProbeClient())
    acc = svc.account()
    assert acc.connected is True
    assert acc.cash == 50_000.0
    pos = svc.positions()
    assert pos.connected is True and len(pos.positions) == 1
    # The fix: no redundant is_connected() pre-probe on the read paths.
    assert calls["is_connected"] == 0


def test_account_disconnected_only_when_fetch_fails():
    svc = _svc(connected=False)
    assert svc.account().connected is False
    assert svc.positions().connected is False


# --- no raw-socket pre-flight (the 502 root cause) --------------------------

class _FakeIB:
    """Stand-in for ib_insync.IB that records the API handshake call."""

    connects: list = []

    def __init__(self):
        self._connected = False

    def connect(self, host, port, clientId, timeout, readonly):
        type(self).connects.append(
            dict(host=host, port=port, clientId=clientId, timeout=timeout,
                 readonly=readonly)
        )
        self._connected = True

    def isConnected(self):
        return self._connected

    def qualifyContracts(self, contract):
        return [contract]

    def placeOrder(self, contract, order):
        class _T:
            class orderStatus:
                status = "SUBMITTED"

            class order:
                orderId = 99

            log = []
        return _T()

    def sleep(self, *_a):
        pass

    def disconnect(self):
        self._connected = False


def _no_raw_socket(monkeypatch):
    """Make ANY raw socket.create_connection blow up, proving the order path
    never opens a bare TCP socket before the ib_insync handshake."""
    import socket as _socket

    def _boom(*_a, **_k):
        raise AssertionError(
            "raw socket pre-flight is forbidden on the IBKR order path"
        )

    monkeypatch.setattr(_socket, "create_connection", _boom)


def _fake_ib_insync(monkeypatch):
    import sys
    import types

    mod = types.ModuleType("ib_insync")
    mod.IB = _FakeIB
    mod.Stock = lambda *a, **k: {"contract": a}
    mod.LimitOrder = lambda *a, **k: {"limit": a}
    mod.MarketOrder = lambda *a, **k: {"market": a}
    monkeypatch.setitem(sys.modules, "ib_insync", mod)


def test_place_order_uses_ib_insync_connect_no_raw_socket(monkeypatch):
    _FakeIB.connects = []
    _no_raw_socket(monkeypatch)
    _fake_ib_insync(monkeypatch)
    client = IBKRClient(IBKRConfig(host="127.0.0.1", port=7497, client_id=21))
    res = client.place_order(
        {"symbol": "700", "exchange": "SEHK", "currency": "HKD"},
        "BUY", 100, "LIMIT", 320.0,
    )
    assert res["status"] == "SUBMITTED"
    # Exactly one ib_insync handshake, with the configured params; no raw
    # socket was opened (else _no_raw_socket would have raised).
    assert len(_FakeIB.connects) == 1
    c = _FakeIB.connects[0]
    assert c["host"] == "127.0.0.1" and c["port"] == 7497
    assert c["clientId"] == 21
    assert c["timeout"] == IBKRConfig().connect_timeout


# --- connect-error classification ------------------------------------------

def test_classify_connection_timeout():
    err = _classify_connect_error(TimeoutError("timed out"))
    assert isinstance(err, IBKRConnectionError)
    assert "timed out" in str(err) or "refused" in str(err)


def test_classify_client_id_in_use():
    err = _classify_connect_error(
        Exception("Unable to connect as the client id is already in use")
    )
    assert isinstance(err, IBKRClientIdInUseError)
    assert "clientId is already in use" in str(err)


def test_classify_read_only_connect():
    err = _classify_connect_error(
        Exception("The API interface is currently in Read-Only mode.")
    )
    assert isinstance(err, IBKRReadOnlyError)


def test_place_order_connect_failure_raises_connection_error(monkeypatch):
    """A connect timeout on the order path -> IBKRConnectionError (clear 502
    reason), never a silent generic failure."""
    import sys
    import types

    class _TimeoutIB(_FakeIB):
        def connect(self, *a, **k):
            raise TimeoutError("connect timed out")

    mod = types.ModuleType("ib_insync")
    mod.IB = _TimeoutIB
    mod.Stock = lambda *a, **k: {}
    mod.LimitOrder = lambda *a, **k: {}
    mod.MarketOrder = lambda *a, **k: {}
    monkeypatch.setitem(sys.modules, "ib_insync", mod)

    client = IBKRClient(IBKRConfig())
    with pytest.raises(IBKRConnectionError) as ei:
        client.place_order(
            {"symbol": "700", "exchange": "SEHK", "currency": "HKD"},
            "BUY", 100, "LIMIT", 320.0,
        )
    assert "timed out" in str(ei.value) or "refused" in str(ei.value)


# --- event-loop in worker thread (the Internal Server Error root cause) -----
# ib_insync/eventkit call asyncio.get_event_loop() at import + use. In a
# FastAPI AnyIO worker thread there is no loop, so it raised
# 'RuntimeError: There is no current event loop'. _ensure_event_loop /
# _import_ib_insync must create one so order/place returns JSON, not a 500.

class _LoopAwareIB(_FakeIB):
    """Like _FakeIB but every entry point touches asyncio.get_event_loop(),
    faithfully reproducing eventkit needing a current loop in this thread."""

    def __init__(self):
        import asyncio
        asyncio.get_event_loop()  # raises if no loop in this thread
        super().__init__()

    def connect(self, *a, **k):
        import asyncio
        asyncio.get_event_loop()
        super().connect(*a, **k)


def _loop_aware_ib_insync(monkeypatch):
    import asyncio
    import sys
    import types

    def _factory(*_a, **_k):
        asyncio.get_event_loop()  # eventkit-style loop requirement
        return {}

    mod = types.ModuleType("ib_insync")
    mod.IB = _LoopAwareIB
    mod.Stock = _factory
    mod.LimitOrder = _factory
    mod.MarketOrder = _factory
    monkeypatch.setitem(sys.modules, "ib_insync", mod)


def _run_in_loopless_thread(fn):
    """Run fn() in a fresh thread that has NO event loop (like an AnyIO worker
    thread), capturing the result or any exception that escapes."""
    import asyncio
    import threading

    box = {}

    def _target():
        # A brand-new thread has no current loop; assert that precondition so
        # the test genuinely exercises the worker-thread path.
        try:
            asyncio.get_event_loop()
            box["had_loop"] = True
        except RuntimeError:
            box["had_loop"] = False
        try:
            box["result"] = fn()
        except BaseException as exc:  # noqa: BLE001
            box["error"] = exc

    t = threading.Thread(target=_target)
    t.start()
    t.join()
    return box


def test_ensure_event_loop_creates_loop_in_loopless_thread():
    box = _run_in_loopless_thread(lambda: type(_ensure_event_loop()).__name__)
    assert box.get("had_loop") is False  # genuinely no loop to start with
    assert "error" not in box, box.get("error")
    assert "EventLoop" in box["result"] or box["result"].endswith("Loop")


def test_import_ib_insync_sets_loop_then_imports(monkeypatch):
    _loop_aware_ib_insync(monkeypatch)
    box = _run_in_loopless_thread(lambda: _import_ib_insync().IB().isConnected())
    # Importing + instantiating IB (which calls get_event_loop) must not raise
    # in a loopless thread because _import_ib_insync set a loop first.
    assert "error" not in box, box.get("error")
    assert box["result"] is False


def test_place_order_in_loopless_worker_thread_no_runtime_error(monkeypatch):
    """Regression: place_order must NOT raise 'no current event loop' when run
    in a worker thread without a loop (the FastAPI AnyIO path)."""
    _LoopAwareIB.connects = []
    _loop_aware_ib_insync(monkeypatch)
    client = IBKRClient(IBKRConfig(host="127.0.0.1", port=7497, client_id=21))

    box = _run_in_loopless_thread(lambda: client.place_order(
        {"symbol": "700", "exchange": "SEHK", "currency": "HKD"},
        "BUY", 100, "LIMIT", 320.0,
    ))
    assert box.get("had_loop") is False
    # No RuntimeError (or anything) escaped, and we got a real order result.
    assert "error" not in box, box.get("error")
    assert box["result"]["status"] == "SUBMITTED"
    assert len(_LoopAwareIB.connects) == 1
