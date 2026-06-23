"""Guard-rail tests for the PRIVATE /v1/broker/moomoo/* live-trading bridge.

No OpenD / Moomoo SDK is required: a fake MoomooService is injected so only the
router gating + plumbing is exercised. Live order placement against a real
broker is NEVER triggered here.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.moomoo import router as moomoo_router
from app.moomoo.service import (
    MoomooAccount,
    MoomooError,
    MoomooOrderResult,
    MoomooPosition,
)

SECRET = "test-moomoo-secret"


class FakeMoomooService:
    """Stand-in for MoomooService that records calls and never touches OpenD.

    Honours the same notional-cap / confirm guard-rails the router relies on
    by delegating to the real preview/place logic where it is pure, but the
    network call (place_order) is replaced with an in-memory stub.
    """

    def __init__(self, cap: float = 1000.0):
        self.cap = cap
        self.placed = []

    def account(self):
        return MoomooAccount(5630.62, 4425.69, 4848.57, 1204.93, "USD")

    def positions(self):
        return [
            MoomooPosition("US.INTC", "INTC", 0.3, 0.3, 140.0, 134.0, -1.7, -4.0),
            MoomooPosition("US.ARM", "ARM", 0.1, 0.1, 442.8, 388.3, -5.4, -12.3),
        ]

    def _est(self, symbol, qty, price):
        if price and price > 0:
            return abs(qty) * price
        for p in self.positions():
            if p.symbol == symbol.split(".")[-1]:
                return abs(qty) * p.last_price
        return 0.0

    def preview(self, symbol, side, qty, order_type, price):
        code = symbol if symbol.startswith("US.") else f"US.{symbol.upper()}"
        otype = (order_type or "MARKET").upper()
        if otype not in ("MARKET", "LIMIT"):
            raise MoomooError("order_type must be MARKET or LIMIT.", 422)
        if otype == "LIMIT" and (price is None or price <= 0):
            raise MoomooError("LIMIT orders require a positive price.", 422)
        est = self._est(code, qty, price or 0.0)
        return {
            "code": code, "symbol": code.split(".")[1], "side": side.upper(),
            "order_type": otype, "quantity": float(qty),
            "price": float(price) if price else 0.0,
            "est_notional": round(est, 2), "max_notional": self.cap,
            "within_cap": est <= self.cap or est == 0.0, "live": True,
            "currency": "USD",
        }

    def place(self, symbol, side, qty, order_type, price, confirm,
              trade_pin=None):
        if not confirm:
            raise MoomooError("Live order requires confirm=true after preview.", 428)
        if not (trade_pin or "").strip():
            raise MoomooError("Trade PIN is required to place a live order.", 428)
        pv = self.preview(symbol, side, qty, order_type, price)
        if not pv["within_cap"] and pv["est_notional"] > 0:
            raise MoomooError("exceeds the per-order cap", 403)
        self.placed.append(pv)
        return MoomooOrderResult(
            order_id="SIM-OID-1", code=pv["code"], side=pv["side"],
            order_type=pv["order_type"], qty=pv["quantity"], price=pv["price"],
            status="SUBMITTING", live=True,
        )

    def cancel(self, order_id):
        return {"order_id": order_id, "status": "CANCELLED", "live": True}


@pytest.fixture()
def fake_svc():
    svc = FakeMoomooService()
    moomoo_router.set_service(svc)
    yield svc
    moomoo_router.set_service(None)


@pytest.fixture()
def client(monkeypatch, fake_svc):
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_SECRET", SECRET)
    c = TestClient(main.app)
    # Register an owner user and pin their uid into the allowlist.
    email = f"owner_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register", json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    token = r.json()["access_token"]
    uid = main._get_auth_service().verify_token(token)
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", str(uid))
    c._owner = {"Authorization": f"Bearer {token}", "X-Moomoo-Secret": SECRET}
    yield c


def test_bridge_disabled_without_secret(monkeypatch, fake_svc):
    monkeypatch.delenv("TRADEWIZZ_MOOMOO_SECRET", raising=False)
    c = TestClient(main.app)
    assert c.get("/v1/broker/moomoo/account").status_code == 503


def test_wrong_secret_is_forbidden(client):
    h = dict(client._owner)
    h["X-Moomoo-Secret"] = "nope"
    assert client.get("/v1/broker/moomoo/account", headers=h).status_code == 403


def test_missing_token_unauthorized(client):
    h = {"X-Moomoo-Secret": SECRET}
    assert client.get("/v1/broker/moomoo/account", headers=h).status_code == 401


def test_non_owner_forbidden(client, monkeypatch):
    # Move the allowlist away from this user's uid.
    monkeypatch.setenv("TRADEWIZZ_MOOMOO_OWNER_UIDS", "999999")
    assert client.get("/v1/broker/moomoo/account",
                      headers=client._owner).status_code == 403


def test_account_and_positions(client):
    a = client.get("/v1/broker/moomoo/account", headers=client._owner)
    assert a.status_code == 200, a.text
    assert a.json()["cash"] == 4425.69 and a.json()["live"] is True
    p = client.get("/v1/broker/moomoo/positions", headers=client._owner)
    assert p.status_code == 200
    syms = {x["symbol"] for x in p.json()["positions"]}
    assert {"INTC", "ARM"} <= syms


def test_preview_does_not_place(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100}
    r = client.post("/v1/broker/moomoo/order/preview", json=body,
                    headers=client._owner)
    assert r.status_code == 200, r.text
    assert r.json()["est_notional"] == 100.0
    assert r.json()["within_cap"] is True
    assert fake_svc.placed == []  # preview never places


def test_place_requires_confirm(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": False}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 428
    assert fake_svc.placed == []


def test_place_requires_pin(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": True}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 428  # confirm ok but no trade_pin
    assert fake_svc.placed == []


def test_place_with_confirm_succeeds(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 1,
            "order_type": "LIMIT", "price": 100, "confirm": True,
            "trade_pin": "123456"}
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 200, r.text
    assert r.json()["order_id"] == "SIM-OID-1"
    assert r.json()["status"] == "SUBMITTING"
    assert len(fake_svc.placed) == 1


def test_notional_cap_blocks_large_order(client, fake_svc):
    body = {"symbol": "INTC", "side": "BUY", "quantity": 100,
            "order_type": "LIMIT", "price": 100, "confirm": True,
            "trade_pin": "123456"}  # $10k > $1k
    r = client.post("/v1/broker/moomoo/order/place", json=body,
                    headers=client._owner)
    assert r.status_code == 403
    assert fake_svc.placed == []


def test_cancel(client):
    r = client.post("/v1/broker/moomoo/order/cancel/OID-9",
                    headers=client._owner)
    assert r.status_code == 200
    assert r.json()["status"] == "CANCELLED"


def test_preview_fractional_market_allowed():
    """Real MoomooService.preview accepts fractional qty for MARKET orders.
    A price is supplied so est_notional returns early WITHOUT touching OpenD
    (positions()), keeping the test hermetic."""
    from app.moomoo.service import MoomooService
    svc = MoomooService()
    # MARKET path with an explicit price avoids the positions() lookup.
    pv = svc.preview("INTC", "BUY", 0.001, "MARKET", 30.0)
    assert pv["quantity"] == 0.001
    assert pv["order_type"] == "MARKET"


def test_preview_fractional_limit_rejected():
    """Fractional qty on a LIMIT order is rejected (422), before any OpenD
    access."""
    from app.moomoo.service import MoomooService, MoomooError
    svc = MoomooService()
    try:
        svc.preview("INTC", "BUY", 0.5, "LIMIT", 30.0)
        assert False, "expected MoomooError"
    except MoomooError as e:
        assert e.status_code == 422
