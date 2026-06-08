"""Regression tests for the stale-singleton IBKRService bug.

The router used to hold a module-level ``IBKRService()`` built once at import,
so it kept a stale config/client: GET /v1/brokers/ibkr/status reported
'IB Gateway not reachable' (default port 7497) while a freshly-built service
from_env() connected fine (port 4002).

These tests pin the fixed behavior:
- get_ibkr_service() with no override builds from the CURRENT environment.
- changing env before a request changes the effective config.
- a test override (set_ibkr_service) still takes precedence.
- /v1/brokers/ibkr/status reflects current env (host/port/client_id/env).
- the portfolio IBKR adapter also uses current env (no stale singleton).
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

from app import main
from app.brokers import router as brokers_router
from app.brokers.adapter import IBKRAdapter
from app.brokers.ibkr_client import MockIBKRClient
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKRService


@pytest.fixture()
def client():
    c = TestClient(main.app)
    yield c
    brokers_router.set_ibkr_service(None)


def _auth_header(c: TestClient) -> dict:
    email = f"fresh_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _set_env(monkeypatch, host, port, client_id, env="paper"):
    monkeypatch.setenv("TRADEWIZZ_IBKR_HOST", host)
    monkeypatch.setenv("TRADEWIZZ_IBKR_PORT", str(port))
    monkeypatch.setenv("TRADEWIZZ_IBKR_CLIENT_ID", str(client_id))
    monkeypatch.setenv("TRADEWIZZ_IBKR_TRADING_ENV", env)


# --- factory uses current env, not a stale singleton -----------------------

def test_get_ibkr_service_uses_current_env(monkeypatch):
    brokers_router.set_ibkr_service(None)
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    svc = brokers_router.get_ibkr_service()
    cfg = svc.config
    assert (cfg.host, cfg.port, cfg.client_id) == ("127.0.0.1", 4002, 21)


def test_changing_env_changes_next_service(monkeypatch):
    brokers_router.set_ibkr_service(None)
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    first = brokers_router.get_ibkr_service().config
    assert first.port == 4002

    # Change env, then a brand-new request-scoped service must reflect it.
    _set_env(monkeypatch, "10.0.0.5", 7497, 7, env="live")
    second = brokers_router.get_ibkr_service().config
    assert (second.host, second.port, second.client_id) == (
        "10.0.0.5", 7497, 7,
    )
    assert second.is_real is True
    # Each call builds a fresh instance (no shared stale object).
    assert brokers_router.get_ibkr_service() is not \
        brokers_router.get_ibkr_service()


def test_test_override_takes_precedence(monkeypatch):
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    override = IBKRService(
        config=IBKRConfig(host="override-host", port=9999, client_id=55),
        client=MockIBKRClient(connected=True),
    )
    brokers_router.set_ibkr_service(override)
    try:
        assert brokers_router.get_ibkr_service() is override
        assert brokers_router.get_ibkr_service().config.port == 9999
    finally:
        brokers_router.set_ibkr_service(None)
    # After clearing, env-fresh again.
    assert brokers_router.get_ibkr_service().config.port == 4002


# --- /v1/brokers/ibkr/status reflects current env --------------------------

def test_status_endpoint_reflects_current_env(client, monkeypatch):
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    # Use a connected mock so we exercise the env-driven config in the
    # response without needing a live IB Gateway.
    brokers_router.set_ibkr_service(IBKRService(
        config=IBKRConfig.from_env(),
        client=MockIBKRClient(connected=True),
    ))
    H = _auth_header(client)
    r = client.get("/v1/brokers/ibkr/status", headers=H)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["connected"] is True
    assert body["host"] == "127.0.0.1"
    assert body["port"] == 4002
    assert body["client_id"] == 21
    assert body["trading_env"] == "PAPER"


def test_status_endpoint_no_override_uses_env(client, monkeypatch):
    """Without any override, the endpoint must build from current env (the
    exact bug: it used to use a stale port-7497 singleton)."""
    brokers_router.set_ibkr_service(None)
    _set_env(monkeypatch, "127.0.0.1", 4002, 33)
    H = _auth_header(client)
    r = client.get("/v1/brokers/ibkr/status", headers=H)
    assert r.status_code == 200, r.text
    body = r.json()
    # Config comes from env even though no gateway is up (connected False is OK).
    assert body["host"] == "127.0.0.1"
    assert body["port"] == 4002
    assert body["client_id"] == 33


# --- portfolio IBKR adapter uses current env -------------------------------

def test_portfolio_ibkr_adapter_uses_current_env(monkeypatch):
    brokers_router.set_ibkr_service(None)
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    adapter = IBKRAdapter()  # default-constructed, as portfolio does
    st = adapter.status()
    assert st.host == "127.0.0.1"
    assert st.port == 4002
    assert st.client_id == 21


def test_portfolio_ibkr_adapter_honors_override(monkeypatch):
    _set_env(monkeypatch, "127.0.0.1", 4002, 21)
    brokers_router.set_ibkr_service(IBKRService(
        config=IBKRConfig(host="ovr", port=9001, client_id=88),
        client=MockIBKRClient(connected=True),
    ))
    try:
        st = IBKRAdapter().status()
        assert st.port == 9001 and st.client_id == 88 and st.connected is True
    finally:
        brokers_router.set_ibkr_service(None)
