"""End-to-end /v1/sim/* endpoints with a real JWT + injected sim service.

Uses a fake price provider + in-memory store so the API path is exercised
without any network or broker dependency.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app import market_config
from app.models import Market
from app.simulation import router as sim_router
from app.simulation.service import SimulationService
from app.simulation.store import SimulationStore

# The sim cash ledger is held in the base accounting currency (IDR). USD orders
# move cash by value*USD_FX. One billion Rupiah of starting cash gives the small
# USD-priced API orders ample headroom once FX-scaled.
USD_FX = market_config.idr_per_unit(Market.US)
INITIAL_CASH = 1_000_000_000.0


class _Universe:
    def symbols(self, market):
        return []  # accept any symbol


@pytest.fixture()
def client():
    svc = SimulationService(
        price_provider=lambda s, m: 100.0,
        store=SimulationStore(":memory:"),
        universe=_Universe(),
        initial_cash=INITIAL_CASH,
    )
    sim_router.set_service(svc)
    c = TestClient(main.app)
    yield c
    # Restore the real (engine-backed) service for other tests.
    sim_router.set_service(
        SimulationService(
            price_provider=lambda s, m: main.engine.latest_price(s, m),
            universe=main.engine._universe,
        )
    )


def _auth(c) -> dict:
    email = f"sim_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def test_account_requires_auth(client):
    assert client.get("/v1/sim/account").status_code == 401


def test_account_shows_initial_simulated_cash(client):
    h = _auth(client)
    r = client.get("/v1/sim/account", headers=h)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["simulated"] is True
    assert j["cash"] == INITIAL_CASH
    assert j["currency"] == "IDR"
    assert "simulated portfolio" in j["disclaimer"].lower()


def test_order_preview_then_place_and_portfolio(client):
    h = _auth(client)
    body = {"symbol": "AAPL", "market": "US", "side": "BUY",
            "quantity": 10, "order_type": "LIMIT", "price": 100}

    pv = client.post("/v1/sim/order/preview", json=body, headers=h).json()
    assert pv["simulated"] is True
    assert "no real broker order" in pv["warning"].lower()
    assert pv["estimated_value"] == 1000.0

    res = client.post("/v1/sim/order/place", json=body, headers=h).json()
    assert res["status"] == "FILLED_SIMULATED"
    assert res["simulated"] is True
    assert "no real broker order" in res["message"].lower()

    port = client.get("/v1/sim/portfolio", headers=h).json()
    assert port["simulated"] is True
    assert len(port["positions"]) == 1
    assert port["positions"][0]["symbol"] == "AAPL"
    # Cash is in the base currency (IDR): a $1000 buy debits 1000*USD_FX.
    assert port["account"]["cash"] == pytest.approx(
        INITIAL_CASH - 1000.0 * USD_FX
    )
    assert port["account"]["currency"] == "IDR"


def test_trades_and_positions_endpoints(client):
    h = _auth(client)
    body = {"symbol": "AAPL", "market": "US", "side": "BUY",
            "quantity": 5, "order_type": "LIMIT", "price": 100}
    client.post("/v1/sim/order/place", json=body, headers=h)

    pos = client.get("/v1/sim/positions", headers=h).json()
    assert pos["simulated"] is True
    assert len(pos["positions"]) == 1

    trades = client.get("/v1/sim/trades", headers=h).json()
    assert trades["simulated"] is True
    assert len(trades["trades"]) == 1
    assert trades["trades"][0]["side"] == "BUY"


def test_insufficient_cash_returns_400(client):
    h = _auth(client)
    body = {"symbol": "AAPL", "market": "US", "side": "BUY",
            "quantity": 1_000_000, "order_type": "LIMIT", "price": 100}
    r = client.post("/v1/sim/order/place", json=body, headers=h)
    assert r.status_code == 400
    assert "cash" in r.json()["detail"].lower()


def test_reset_endpoint(client):
    h = _auth(client)
    body = {"symbol": "AAPL", "market": "US", "side": "BUY",
            "quantity": 5, "order_type": "LIMIT", "price": 100}
    client.post("/v1/sim/order/place", json=body, headers=h)
    r = client.post("/v1/sim/reset", headers=h).json()
    assert r["simulated"] is True
    assert r["cash"] == INITIAL_CASH
    assert client.get("/v1/sim/positions", headers=h).json()["positions"] == []


@pytest.mark.parametrize("symbol,market", [
    ("AAPL", "US"), ("0700", "HKEX"), ("7203", "JAPAN"),
    ("RELIANCE", "INDIA"), ("VCB", "VIETNAM"), ("D05", "SINGAPORE"),
    ("BBCA", "IDX"), ("005930", "KOSPI"), ("035720", "KOSDAQ"),
])
def test_all_markets_buyable_via_api(client, symbol, market):
    h = _auth(client)
    body = {"symbol": symbol, "market": market, "side": "BUY",
            "quantity": 1, "order_type": "LIMIT", "price": 50}
    r = client.post("/v1/sim/order/place", json=body, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "FILLED_SIMULATED"
