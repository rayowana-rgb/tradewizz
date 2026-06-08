"""Portfolio<->status consistency for IBKR (req 7).

Pins: if /v1/brokers/ibkr/status reports connected=true, /v1/portfolio must
include IBKR cash/equity/positions and must NOT report 'IBKR is not reachable'
unless account_summary() fails in that exact request. Moomoo must never mask
IBKR. Portfolio must use the same env/config (client_id) as status.
"""

from __future__ import annotations

import uuid

import pytest

from app.brokers.adapter import IBKRAdapter, MoomooAdapter
from app.brokers.ibkr_client import IBKRError, MockIBKRClient
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKRService
from app.brokers.models import BrokerType
from app.brokers.service import BrokerConnectionService
from app.brokers.store import InMemoryConnectionStore
from app.broker.client import MockBrokerClient
from app.broker.config import BrokerConfig
from app.broker.service import BrokerService
from app.portfolio.service import PortfolioService


# --- helpers ---------------------------------------------------------------

def _ibkr_adapter(client):
    return IBKRAdapter(
        service=IBKRService(config=IBKRConfig.from_env(), client=client)
    )


def _moomoo_adapter(connected=True):
    return MoomooAdapter(service=BrokerService(
        config=BrokerConfig(trading_env="paper"),
        client=MockBrokerClient(connected=connected),
    ))


def _conns(*broker_types):
    conns = BrokerConnectionService(store=InMemoryConnectionStore())
    for bt in broker_types:
        conns.store.create(1, bt, bt.value)
    return conns


def _factory(ibkr_client, moomoo_connected=True):
    def factory(bt):
        if bt is BrokerType.MOOMOO:
            return _moomoo_adapter(connected=moomoo_connected)
        return _ibkr_adapter(ibkr_client)
    return factory


@pytest.fixture()
def env(monkeypatch):
    monkeypatch.setenv("TRADEWIZZ_IBKR_HOST", "127.0.0.1")
    monkeypatch.setenv("TRADEWIZZ_IBKR_PORT", "4002")
    monkeypatch.setenv("TRADEWIZZ_IBKR_CLIENT_ID", "33")
    monkeypatch.setenv("TRADEWIZZ_IBKR_TRADING_ENV", "paper")


# --- status connected=true => portfolio includes IBKR cash/equity ----------

def test_status_connected_portfolio_includes_ibkr(env):
    client = MockIBKRClient(connected=True)
    # status path
    status = IBKRService(config=IBKRConfig.from_env(), client=client).status()
    assert status.connected is True

    conns = _conns(BrokerType.IBKR)
    svc = PortfolioService(connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)

    assert "IBKR" in p.brokers
    assert p.summary.cash == 50000.0           # from MockIBKRClient
    assert p.summary.total_equity == 75000.0   # NetLiquidation
    assert not any(
        "not reachable" in e.message for e in p.errors if e.broker == "IBKR"
    )


def test_status_connected_portfolio_includes_ibkr_positions(env):
    client = MockIBKRClient(connected=True)
    conns = _conns(BrokerType.IBKR)
    svc = PortfolioService(connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)
    ibkr_pos = [pos for pos in p.positions if pos.broker == "IBKR"]
    assert len(ibkr_pos) == 1
    assert ibkr_pos[0].symbol == "AAPL"


# --- account connected=true does NOT add 'not reachable' -------------------

def test_account_connected_no_not_reachable_error(env):
    client = MockIBKRClient(connected=True)
    conns = _conns(BrokerType.IBKR)
    svc = PortfolioService(connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)
    assert all(
        "not reachable" not in e.message
        for e in p.errors if e.broker == "IBKR"
    )


# --- positions connected=true does NOT add 'not reachable' -----------------

def test_positions_connected_no_not_reachable_error(env):
    client = MockIBKRClient(connected=True)
    conns = _conns(BrokerType.IBKR)
    svc = PortfolioService(connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)
    # IBKR contributed via positions; no not-reachable error.
    assert "IBKR" in p.brokers
    assert not any(
        "not reachable" in e.message for e in p.errors if e.broker == "IBKR"
    )


# --- portfolio uses same config/client_id as status ------------------------

def test_portfolio_uses_same_client_id_as_status(env):
    status_cfg = IBKRService(config=IBKRConfig.from_env()).config
    adapter = IBKRAdapter()  # built exactly like the portfolio path
    assert adapter._service.config.client_id == status_cfg.client_id == 33
    assert adapter._service.config.host == status_cfg.host
    assert adapter._service.config.port == status_cfg.port


# --- Moomoo failure must NOT hide IBKR -------------------------------------

def test_moomoo_failure_does_not_hide_ibkr(env):
    client = MockIBKRClient(connected=True)
    conns = _conns(BrokerType.MOOMOO, BrokerType.IBKR)
    svc = PortfolioService(
        connections=conns,
        adapter_factory=_factory(client, moomoo_connected=False),
    )
    p = svc.for_user(1)
    # IBKR still present with its cash despite Moomoo being down.
    assert "IBKR" in p.brokers
    assert p.summary.cash == 50000.0
    # Moomoo down is recorded but does not remove IBKR.
    assert any(e.broker == "MOOMOO" for e in p.errors)


def test_moomoo_connected_and_ibkr_both_included(env):
    client = MockIBKRClient(connected=True)
    conns = _conns(BrokerType.MOOMOO, BrokerType.IBKR)
    svc = PortfolioService(
        connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)
    assert "IBKR" in p.brokers
    assert "MOOMOO" in p.brokers
    # Both brokers' cash aggregated (Moomoo 100k + IBKR 50k).
    assert p.summary.cash == 150000.0


# --- the ONLY case that yields 'not reachable' is account_summary failure --

def test_account_summary_failure_is_only_not_reachable_case(env):
    # account_summary raises -> account.connected=False -> not reachable.
    client = MockIBKRClient(connected=False)
    conns = _conns(BrokerType.IBKR)
    svc = PortfolioService(connections=conns, adapter_factory=_factory(client))
    p = svc.for_user(1)
    assert "IBKR" not in p.brokers
    assert any(
        e.broker == "IBKR" and "not reachable" in e.message
        for e in p.errors
    )
