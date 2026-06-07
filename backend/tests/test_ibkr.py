"""IBKR adapter/service tests (no network; mock IB client)."""

import pytest

from app.broker.models import OrderSide, OrderType
from app.brokers.adapter import IBKRAdapter
from app.brokers.ibkr_client import IBKRClient, IBKRError, MockIBKRClient
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
