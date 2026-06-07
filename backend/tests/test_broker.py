"""Broker (Moomoo) tests: symbol mapping + safety flow with a mock client.

No network, no real orders. The MockBrokerClient records orders in memory.
"""

import time

import pytest
from fastapi.testclient import TestClient

from app import main
from app.broker.client import MockBrokerClient
from app.broker.config import BrokerConfig
from app.broker.models import OrderSide, OrderType
from app.broker.router import set_service
from app.broker.service import BrokerService, OrderValidationError
from app.broker.symbol_map import (
    SymbolNotTradable,
    is_market_tradable,
    to_moomoo_code,
)
from app.models import Market


# --- symbol mapping ---------------------------------------------------------

def test_hk_symbol_maps_to_padded_code():
    assert to_moomoo_code("0700", Market.HKEX) == "HK.00700"
    assert to_moomoo_code("700", Market.HKEX) == "HK.00700"
    assert to_moomoo_code("9988", Market.HKEX) == "HK.09988"


@pytest.mark.parametrize("market", [Market.IDX, Market.KOSPI, Market.KOSDAQ])
def test_unsupported_markets_are_not_tradable(market):
    assert not is_market_tradable(market)
    with pytest.raises(SymbolNotTradable):
        to_moomoo_code("BBCA", market)


def test_hkex_non_numeric_symbol_rejected():
    with pytest.raises(SymbolNotTradable):
        to_moomoo_code("TENCENT", Market.HKEX)


# --- service: paper/real status ---------------------------------------------

def _svc(trading_env="paper", connected=True, **cfg):
    config = BrokerConfig(trading_env=trading_env, **cfg)
    return BrokerService(
        config=config, client=MockBrokerClient(connected=connected)
    )


def test_status_paper_has_no_warning():
    s = _svc("paper").status()
    assert s.trading_env == "PAPER"
    assert s.is_real is False
    assert s.warning is None


def test_status_real_shows_warning():
    s = _svc("real").status()
    assert s.trading_env == "REAL"
    assert s.is_real is True
    assert s.warning and "REAL TRADING" in s.warning


def test_status_disconnected_when_opend_down():
    s = _svc(connected=False).status()
    assert s.connected is False


# --- preview never places ---------------------------------------------------

def test_preview_does_not_place_order():
    client = MockBrokerClient()
    svc = BrokerService(config=BrokerConfig(), client=client)
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    assert pv.moomoo_code == "HK.00700"
    assert pv.confirmation_token
    assert pv.trading_env == "PAPER"
    # Nothing was placed.
    assert client.list_orders() == []


# --- place requires confirmation --------------------------------------------

def test_place_without_token_fails():
    svc = _svc()
    with pytest.raises(OrderValidationError):
        svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                  OrderType.LIMIT, 400.0, confirmation_token="")


def test_place_with_wrong_token_fails():
    svc = _svc()
    with pytest.raises(OrderValidationError):
        svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                  OrderType.LIMIT, 400.0, confirmation_token="123.deadbeef")


def test_place_with_valid_token_succeeds():
    svc = _svc()
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    res = svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 400.0, pv.confirmation_token)
    assert res.status == "SUBMITTED"
    assert res.order_id.startswith("MOCK-")


def test_token_for_one_order_does_not_authorize_a_different_order():
    svc = _svc()
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    # Different quantity -> token must not validate.
    with pytest.raises(OrderValidationError):
        svc.place("0700", Market.HKEX, OrderSide.BUY, 200,
                  OrderType.LIMIT, 400.0, pv.confirmation_token)


def test_expired_token_fails():
    clock = {"t": 1000.0}
    svc = BrokerService(
        config=BrokerConfig(confirmation_ttl_seconds=60),
        client=MockBrokerClient(), clock=lambda: clock["t"],
    )
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    clock["t"] += 61  # past TTL
    with pytest.raises(OrderValidationError):
        svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                  OrderType.LIMIT, 400.0, pv.confirmation_token)


# --- unsupported symbols fail safely ----------------------------------------

def test_preview_unsupported_market_errors():
    svc = _svc()
    with pytest.raises(OrderValidationError) as ei:
        svc.preview("BBCA", Market.IDX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 5000.0)
    assert "not tradable via Moomoo" in str(ei.value)


# --- risk controls ----------------------------------------------------------

def test_limit_requires_price():
    svc = _svc()
    with pytest.raises(OrderValidationError):
        svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, None)


def test_max_quantity_enforced():
    svc = _svc(max_order_quantity=50)
    with pytest.raises(OrderValidationError):
        svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 400.0)


def test_max_order_value_enforced():
    svc = _svc(max_order_value=1000)
    with pytest.raises(OrderValidationError):
        svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 400.0)  # 40,000 > 1,000


# --- duplicate guard --------------------------------------------------------

def test_duplicate_order_guard():
    clock = {"t": 1000.0}
    svc = BrokerService(
        config=BrokerConfig(duplicate_window_seconds=30,
                            confirmation_ttl_seconds=300),
        client=MockBrokerClient(), clock=lambda: clock["t"],
    )
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
              OrderType.LIMIT, 400.0, pv.confirmation_token)
    # Immediate identical order within the window -> blocked.
    pv2 = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                      OrderType.LIMIT, 400.0)
    with pytest.raises(OrderValidationError) as ei:
        svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                  OrderType.LIMIT, 400.0, pv2.confirmation_token)
    assert "Duplicate" in str(ei.value)


# --- cancel -----------------------------------------------------------------

def test_cancel_order():
    svc = _svc()
    pv = svc.preview("0700", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 400.0)
    res = svc.place("0700", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 400.0, pv.confirmation_token)
    cancelled = svc.cancel(res.order_id)
    assert cancelled.cancelled is True


# --- API endpoints (TestClient + mock service) ------------------------------

@pytest.fixture()
def client():
    set_service(BrokerService(config=BrokerConfig(trading_env="paper"),
                              client=MockBrokerClient()))
    yield TestClient(main.app)
    # Restore a default (disconnected real) service after the test.
    set_service(BrokerService(client=MockBrokerClient(connected=False)))


def test_api_status_paper(client):
    b = client.get("/v1/broker/status").json()
    assert b["trading_env"] == "PAPER"
    assert b["is_real"] is False


def test_api_preview_then_place(client):
    pv = client.post("/v1/broker/order/preview", json={
        "symbol": "0700", "market": "HKEX", "side": "BUY",
        "quantity": 100, "order_type": "LIMIT", "price": 400,
    }).json()
    assert pv["moomoo_code"] == "HK.00700"
    place = client.post("/v1/broker/order/place", json={
        "symbol": "0700", "market": "HKEX", "side": "BUY",
        "quantity": 100, "order_type": "LIMIT", "price": 400,
        "confirmation_token": pv["confirmation_token"],
    })
    assert place.status_code == 200
    assert place.json()["status"] == "SUBMITTED"


def test_api_place_without_token_is_400(client):
    r = client.post("/v1/broker/order/place", json={
        "symbol": "0700", "market": "HKEX", "side": "BUY",
        "quantity": 100, "order_type": "LIMIT", "price": 400,
        "confirmation_token": "",
    })
    assert r.status_code == 400


def test_api_unsupported_symbol_is_400(client):
    r = client.post("/v1/broker/order/preview", json={
        "symbol": "BBCA", "market": "IDX", "side": "BUY",
        "quantity": 100, "order_type": "LIMIT", "price": 5000,
    })
    assert r.status_code == 400
    assert "not tradable" in r.json()["detail"]


# --- OpenD-down resilience (port closed) -------------------------------------

def _free_port():
    """Return a definitely-closed local port (bind, read, release)."""
    import socket as _s
    s = _s.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def test_real_client_disconnected_fast_when_port_closed():
    import time as _t
    from app.broker.client import MoomooBrokerClient

    cfg = BrokerConfig(host="127.0.0.1", port=_free_port())
    client = MoomooBrokerClient(cfg)
    t0 = _t.time()
    connected = client.is_connected()
    elapsed = _t.time() - t0
    assert connected is False
    # Fast pre-flight: well under the SDK reconnect timeout.
    assert elapsed < 2.0


def test_sdk_not_called_when_socket_check_fails(monkeypatch):
    # If the SDK were imported/called, this would blow up; the port probe must
    # short-circuit before any SDK usage.
    from app.broker import client as bc

    cfg = BrokerConfig(host="127.0.0.1", port=_free_port())
    monkeypatch.setattr(bc, "_port_open", lambda *a, **k: False)
    called = {"sdk": False}

    def _boom(self):
        called["sdk"] = True
        raise AssertionError("SDK context must not be created when port closed")

    monkeypatch.setattr(bc.MoomooBrokerClient, "_context", _boom)
    client = bc.MoomooBrokerClient(cfg)
    assert client.is_connected() is False
    assert called["sdk"] is False


def test_status_endpoint_does_not_crash_when_opend_missing():
    from app.broker.client import MoomooBrokerClient

    cfg = BrokerConfig(host="127.0.0.1", port=_free_port(), trading_env="paper")
    svc = BrokerService(config=cfg, client=MoomooBrokerClient(cfg))
    status = svc.status()
    assert status.connected is False
    assert status.trading_env == "PAPER"
    assert status.message == "Moomoo OpenD not reachable"
    assert status.warning is None


def test_status_endpoint_real_mode_warns_when_opend_missing():
    from app.broker.client import MoomooBrokerClient

    cfg = BrokerConfig(host="127.0.0.1", port=_free_port(), trading_env="real")
    svc = BrokerService(config=cfg, client=MoomooBrokerClient(cfg))
    status = svc.status()
    assert status.connected is False
    assert status.is_real is True
    assert status.warning and "REAL TRADING" in status.warning


def test_port_open_false_for_closed_port():
    from app.broker.client import _port_open

    assert _port_open("127.0.0.1", _free_port(), timeout=0.5) is False
