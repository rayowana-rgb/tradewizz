"""API tests for the authenticated IBKR order flow.

Exercises the real route chain Flutter uses:
    POST /v1/brokers/ibkr/order/preview  -> confirmation token
    POST /v1/brokers/ibkr/order/place    -> IBKR transmit (mock client)

Covers: preview success + token, place success, read-only rejection (clear
message), insufficient-funds rejection, invalid symbol rejection, missing auth.
No network: the IBKR client is a MockIBKRClient.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

from app import main
from app.brokers import router as brokers_router
from app.brokers.ibkr_client import (
    IBKRClientIdInUseError,
    IBKRConnectionError,
    MockIBKRClient,
)
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKRService


@pytest.fixture()
def client():
    c = TestClient(main.app)
    yield c
    # Reset the IBKR service to a default after each test.
    brokers_router.set_ibkr_service(IBKRService())


def _auth_header(c: TestClient) -> dict:
    email = f"trader_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _install(mock_client) -> None:
    brokers_router.set_ibkr_service(
        IBKRService(config=IBKRConfig(), client=mock_client)
    )


def _order(**kw):
    base = {"symbol": "700", "market": "HKEX",
            "order_type": "LIMIT", "price": 180}
    base.update(kw)
    return base


def test_preview_returns_confirmation_token(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True))
    r = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                    json=_order(side="BUY", quantity=10))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["confirmation_token"]
    assert body["trading_env"] == "PAPER"
    assert body["estimated_value"] == 1800.0


def test_place_succeeds_with_token(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True))
    pv = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                     json=_order(side="BUY", quantity=10)).json()
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="BUY", quantity=10,
                                confirmation_token=pv["confirmation_token"]))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "SUBMITTED"
    assert body["order_id"].startswith("IBKR-")
    assert body["trading_env"] == "PAPER"


def test_place_read_only_mode_returns_clear_error(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True, read_only=True))
    pv = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                     json=_order(side="SELL", quantity=5,
                                 order_type="MARKET", price=None)).json()
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="SELL", quantity=5, order_type="MARKET",
                                price=None,
                                confirmation_token=pv["confirmation_token"]))
    assert r.status_code == 409
    assert "Read-Only" in r.json()["detail"]
    assert "Disable Read-Only" in r.json()["detail"]


def test_place_insufficient_funds_returns_clear_error(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True, insufficient=True))
    pv = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                     json=_order(side="BUY", quantity=5)).json()
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="BUY", quantity=5,
                                confirmation_token=pv["confirmation_token"]))
    assert r.status_code == 400
    assert "Insufficient buying power" in r.json()["detail"]


def test_invalid_symbol_rejected(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True))
    r = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                    json={"symbol": "BBCA", "market": "IDX", "side": "BUY",
                          "quantity": 5, "order_type": "MARKET"})
    assert r.status_code == 400
    assert "not tradable via IBKR" in r.json()["detail"]


def test_order_requires_authentication(client):
    _install(MockIBKRClient(connected=True))
    r = client.post("/v1/brokers/ibkr/order/preview",
                    json=_order(side="BUY", quantity=5))
    assert r.status_code == 401


def test_place_with_bad_token_rejected(client):
    H = _auth_header(client)
    _install(MockIBKRClient(connected=True))
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="BUY", quantity=10,
                                confirmation_token="bogus.token"))
    assert r.status_code == 400
    assert "token" in r.json()["detail"].lower()


def test_place_connection_failure_returns_clear_502(client):
    """A connect timeout/refused must surface a specific 502 reason, never the
    generic 'IB Gateway is not reachable; order not placed.'"""
    H = _auth_header(client)
    _install(MockIBKRClient(
        connected=True,
        place_error=IBKRConnectionError(
            "IB Gateway connection timed out / refused: timed out"
        ),
    ))
    pv = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                     json=_order(side="BUY", quantity=10)).json()
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="BUY", quantity=10,
                                confirmation_token=pv["confirmation_token"]))
    assert r.status_code == 502
    detail = r.json()["detail"]
    assert "timed out" in detail or "refused" in detail
    assert "not reachable; order not placed" not in detail


def test_place_client_id_conflict_returns_clear_message(client):
    """clientId already in use -> a clear, specific message (409), not 502."""
    H = _auth_header(client)
    _install(MockIBKRClient(
        connected=True,
        place_error=IBKRClientIdInUseError(
            "IB Gateway clientId is already in use by another connection. "
            "Close the other session or change TRADEWIZZ_IBKR_CLIENT_ID."
        ),
    ))
    pv = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                     json=_order(side="BUY", quantity=10)).json()
    r = client.post("/v1/brokers/ibkr/order/place", headers=H,
                    json=_order(side="BUY", quantity=10,
                                confirmation_token=pv["confirmation_token"]))
    assert r.status_code == 409
    assert "clientId is already in use" in r.json()["detail"]


def test_place_unsupported_hkex_symbol_fails_safely(client):
    """A non-tradable symbol is rejected at validation (400) before any
    connection is attempted — it can never reach place_order."""
    H = _auth_header(client)
    _install(MockIBKRClient(
        connected=True,
        place_error=AssertionError("place_order must NOT be called"),
    ))
    r = client.post("/v1/brokers/ibkr/order/preview", headers=H,
                    json={"symbol": "KOSPI200", "market": "KOSPI",
                          "side": "BUY", "quantity": 5, "order_type": "MARKET"})
    assert r.status_code == 400
    assert "not tradable via IBKR" in r.json()["detail"]
