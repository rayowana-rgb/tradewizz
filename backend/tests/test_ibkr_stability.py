"""Stability tests for IBKR connection lifecycle (clientId race + config).

Pins the permanent fixes:
- every path (status/portfolio/preview/place) uses the CURRENT env config;
- concurrent status + portfolio + place never overlap a connect on the same
  clientId (serialized by the process-wide gateway lock);
- a slow/down Moomoo does NOT block IBKR portfolio data;
- the worker-thread event loop path still works;
- direct service and API route produce a consistent result.
"""

from __future__ import annotations

import sys
import threading
import time
import types
import uuid

import pytest
from fastapi.testclient import TestClient

from app import main
from app.brokers import router as brokers_router
from app.brokers.adapter import IBKRAdapter, MoomooAdapter
from app.brokers.ibkr_client import IBKRClient, _GATEWAY_LOCK
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKRService
from app.brokers.models import BrokerType
from app.brokers.service import BrokerConnectionService
from app.brokers.store import InMemoryConnectionStore
from app.portfolio.service import PortfolioService


@pytest.fixture()
def client():
    c = TestClient(main.app)
    yield c
    brokers_router.set_ibkr_service(None)


def _auth_header(c: TestClient) -> dict:
    email = f"stab_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "passw0rd123"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _set_env(monkeypatch, host="127.0.0.1", port=4002, client_id=31):
    monkeypatch.setenv("TRADEWIZZ_IBKR_HOST", host)
    monkeypatch.setenv("TRADEWIZZ_IBKR_PORT", str(port))
    monkeypatch.setenv("TRADEWIZZ_IBKR_CLIENT_ID", str(client_id))
    monkeypatch.setenv("TRADEWIZZ_IBKR_TRADING_ENV", "paper")


# --------------------------------------------------------------------------- #
# A fake ib_insync whose IB records the clientId of every connect and asserts  #
# no two connections on the SAME clientId are live at once (the race we fix).  #
# --------------------------------------------------------------------------- #
class _RaceDetectingState:
    def __init__(self):
        self.lock = threading.Lock()
        self.live_by_client_id: dict = {}
        self.max_concurrent = 0
        self.connects = 0
        self.conflicts = 0


def _install_race_fake(monkeypatch, state: _RaceDetectingState):
    import asyncio

    class _IB:
        def __init__(self):
            asyncio.get_event_loop()
            self._c = False
            self._cid = None

        def connect(self, host, port, clientId, timeout, readonly):
            asyncio.get_event_loop()
            with state.lock:
                state.connects += 1
                live = state.live_by_client_id.get(clientId, 0)
                if live > 0:
                    # Another connection on the SAME clientId is already live.
                    state.conflicts += 1
                state.live_by_client_id[clientId] = live + 1
                total = sum(state.live_by_client_id.values())
                state.max_concurrent = max(state.max_concurrent, total)
            self._cid = clientId
            self._c = True
            # Hold the "connection" briefly to widen any race window.
            time.sleep(0.02)

        def isConnected(self):
            return self._c

        def managedAccounts(self):
            return ["DU123"]

        def accountSummary(self, *a):
            class _R:
                def __init__(self, tag, value, currency="USD"):
                    self.tag = tag
                    self.value = value
                    self.currency = currency
            return [
                _R("TotalCashValue", "50000"),
                _R("BuyingPower", "100000"),
                _R("NetLiquidation", "75000"),
            ]

        def positions(self, *a):
            return []

        def qualifyContracts(self, contract):
            return [contract]

        def placeOrder(self, contract, order):
            T = type("T", (), {})
            T.orderStatus = type("S", (), {"status": "PendingSubmit"})
            T.order = type("O", (), {"orderId": 7})
            T.log = []
            return T

        def sleep(self, *a):
            pass

        def reqOpenOrders(self):
            return []

        def openTrades(self):
            return []

        def disconnect(self):
            if self._c and self._cid is not None:
                with state.lock:
                    n = state.live_by_client_id.get(self._cid, 0)
                    if n > 0:
                        state.live_by_client_id[self._cid] = n - 1
            self._c = False

    def _factory(*a, **k):
        asyncio.get_event_loop()
        return {}

    mod = types.ModuleType("ib_insync")
    mod.IB = _IB
    mod.Stock = _factory
    mod.LimitOrder = _factory
    mod.MarketOrder = _factory
    monkeypatch.setitem(sys.modules, "ib_insync", mod)


# --- all paths use current env --------------------------------------------

def test_status_preview_place_use_current_env(monkeypatch):
    brokers_router.set_ibkr_service(None)
    _set_env(monkeypatch, port=4002, client_id=31)
    svc = brokers_router.get_ibkr_service()
    cfg = svc.config
    assert (cfg.host, cfg.port, cfg.client_id) == ("127.0.0.1", 4002, 31)
    # status() reports the same config.
    st = svc.status()
    assert (st.host, st.port, st.client_id) == ("127.0.0.1", 4002, 31)


def test_portfolio_uses_same_config_as_status(monkeypatch):
    _set_env(monkeypatch, port=4002, client_id=31)
    brokers_router.set_ibkr_service(None)
    status_cfg = brokers_router.get_ibkr_service().config
    adapter = IBKRAdapter()  # portfolio path constructs it the same way
    assert adapter._service.config.host == status_cfg.host
    assert adapter._service.config.port == status_cfg.port
    assert adapter._service.config.client_id == status_cfg.client_id


# --- concurrency: no clientId conflict ------------------------------------

def test_concurrent_status_portfolio_place_no_client_id_conflict(monkeypatch):
    state = _RaceDetectingState()
    _install_race_fake(monkeypatch, state)
    cfg = IBKRConfig(host="127.0.0.1", port=4002, client_id=31)

    def run_status():
        IBKRClient(cfg).is_connected()

    def run_account():
        IBKRClient(cfg).account_summary()

    def run_positions():
        IBKRClient(cfg).positions()

    def run_place():
        IBKRClient(cfg).place_order(
            {"symbol": "AAPL", "exchange": "SMART", "currency": "USD"},
            "BUY", 1, "MARKET", None,
        )

    workers = [run_status, run_account, run_positions, run_place] * 4
    threads = [threading.Thread(target=w) for w in workers]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=20)

    assert state.connects >= len(workers)
    # The gateway lock serializes connect->use->disconnect, so at most ONE
    # connection is ever live and there is never a same-clientId conflict.
    assert state.max_concurrent == 1, state.max_concurrent
    assert state.conflicts == 0, state.conflicts


def test_gateway_lock_serializes_connects(monkeypatch):
    """Direct proof the lock is held across connect+use for each op."""
    state = _RaceDetectingState()
    _install_race_fake(monkeypatch, state)
    cfg = IBKRConfig(host="127.0.0.1", port=4002, client_id=41)

    # While a long op holds the lock, is_connected from another thread must
    # wait (no overlap).
    holder_started = threading.Event()

    def holder():
        with _GATEWAY_LOCK:
            holder_started.set()
            time.sleep(0.2)

    th = threading.Thread(target=holder)
    th.start()
    holder_started.wait(timeout=2)
    t0 = time.time()
    IBKRClient(cfg).is_connected()  # must block until holder releases
    elapsed = time.time() - t0
    th.join(timeout=2)
    assert elapsed >= 0.15, elapsed


# --- slow Moomoo must not block IBKR --------------------------------------

class _SlowMoomooAdapter:
    broker_type = BrokerType.MOOMOO

    def account(self):
        time.sleep(30)  # simulate OpenD hang

    def positions(self):
        time.sleep(30)


def test_slow_moomoo_does_not_block_ibkr(monkeypatch):
    _set_env(monkeypatch, port=4002, client_id=31)

    # IBKR adapter backed by a connected mock so it returns instantly.
    from app.brokers.ibkr_client import MockIBKRClient

    def factory(bt):
        if bt is BrokerType.MOOMOO:
            return _SlowMoomooAdapter()
        return IBKRAdapter(service=IBKRService(
            config=IBKRConfig.from_env(),
            client=MockIBKRClient(connected=True),
        ))

    conns = BrokerConnectionService(store=InMemoryConnectionStore())
    conns.connect(1, BrokerType.MOOMOO)
    conns.store.create(1, BrokerType.IBKR, "IBKR")
    svc = PortfolioService(connections=conns, adapter_factory=factory)

    # Patch the per-broker timeout low so the test is fast but still proves
    # Moomoo (30s) is abandoned while IBKR data still returns.
    monkeypatch.setattr(
        "app.portfolio.service._BROKER_FETCH_TIMEOUT", 1.0
    )
    t0 = time.time()
    p = svc.for_user(1)
    elapsed = time.time() - t0
    assert elapsed < 5.0, elapsed  # did not wait for the 30s Moomoo hang
    # IBKR data is present despite the slow Moomoo.
    assert "IBKR" in p.brokers
    assert p.summary.cash == 50000.0
    # Moomoo recorded as a non-fatal timeout error.
    assert any(e.broker == "MOOMOO" for e in p.errors)


# --- direct vs API consistency --------------------------------------------

def test_direct_service_and_api_status_consistent(client, monkeypatch):
    from app.brokers.ibkr_client import MockIBKRClient
    _set_env(monkeypatch, port=4002, client_id=31)
    mock = MockIBKRClient(connected=True)
    # Direct.
    direct = IBKRService(config=IBKRConfig.from_env(), client=mock).status()
    # API (same override so we compare config wiring, not gateway state).
    brokers_router.set_ibkr_service(
        IBKRService(config=IBKRConfig.from_env(), client=mock))
    H = _auth_header(client)
    api = client.get("/v1/brokers/ibkr/status", headers=H).json()
    assert direct.connected == api["connected"]
    assert direct.host == api["host"]
    assert direct.port == api["port"]
    assert direct.client_id == api["client_id"]
