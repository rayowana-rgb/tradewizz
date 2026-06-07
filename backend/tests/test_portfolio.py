"""Unified portfolio tests (no network; mock Moomoo + IBKR stub)."""

import pytest
from fastapi.testclient import TestClient

from app import main
from app.auth.config import AuthConfig
from app.auth.router import set_service as set_auth_service
from app.auth.service import AuthService
from app.auth.store import InMemoryUserStore
from app.broker.client import MockBrokerClient
from app.broker.config import BrokerConfig
from app.broker.service import BrokerService
from app.brokers.adapter import IBKRAdapter, MoomooAdapter
from app.brokers.models import BrokerType
from app.brokers.router import set_service as set_conn_service
from app.brokers.service import BrokerConnectionService
from app.brokers.store import InMemoryConnectionStore
from app.portfolio.router import set_service as set_portfolio_service
from app.portfolio.service import PortfolioService


def _moomoo_adapter(connected=True):
    return MoomooAdapter(
        service=BrokerService(
            config=BrokerConfig(trading_env="paper"),
            client=MockBrokerClient(connected=connected),
        )
    )


def _factory(connected=True):
    def factory(bt):
        if bt == BrokerType.MOOMOO:
            return _moomoo_adapter(connected=connected)
        return IBKRAdapter()
    return factory


def _conns():
    return BrokerConnectionService(store=InMemoryConnectionStore())


# --- service ----------------------------------------------------------------

def test_no_connections_returns_empty_portfolio():
    svc = PortfolioService(connections=_conns(), adapter_factory=_factory())
    p = svc.for_user(1)
    assert p.summary.total_equity == 0.0
    assert p.positions == []
    assert p.brokers == []


def test_moomoo_only_aggregates():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    svc = PortfolioService(connections=conns, adapter_factory=_factory())
    p = svc.for_user(1)
    assert p.brokers == ["MOOMOO"]
    assert p.summary.total_equity == 150000.0
    assert p.summary.cash == 100000.0
    assert p.summary.buying_power == 200000.0
    assert p.summary.market_value == 41260.0
    assert p.summary.floating_pnl == 3260.0
    assert p.summary.realized_pnl == 0.0
    assert len(p.positions) == 1
    pos = p.positions[0]
    assert pos.broker == "MOOMOO"
    assert pos.quantity == 100.0
    assert pos.unrealized_pnl == 3260.0


def test_ibkr_stub_does_not_break_aggregation():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    conns.store.create(1, BrokerType.IBKR, "IBKR")  # force a stub connection
    svc = PortfolioService(connections=conns, adapter_factory=_factory())
    p = svc.for_user(1)
    # Moomoo still aggregated.
    assert "MOOMOO" in p.brokers
    assert p.summary.total_equity == 150000.0
    # IBKR recorded as a non-fatal error.
    assert any(e.broker == "IBKR" for e in p.errors)


def test_disconnected_broker_records_error_only():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    svc = PortfolioService(
        connections=conns, adapter_factory=_factory(connected=False)
    )
    p = svc.for_user(1)
    # Disconnected Moomoo -> account 'connected: False' contributes nothing.
    assert p.summary.total_equity == 0.0
    # No positions, but also no crash.
    assert p.positions == []


def test_portfolio_is_per_user():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    svc = PortfolioService(connections=conns, adapter_factory=_factory())
    assert svc.for_user(1).summary.total_equity == 150000.0
    assert svc.for_user(2).summary.total_equity == 0.0  # user 2 has none


# --- API (auth-scoped) ------------------------------------------------------

@pytest.fixture()
def client():
    auth = AuthService(config=AuthConfig(jwt_secret="t"),
                       store=InMemoryUserStore())
    conns = _conns()
    set_auth_service(auth)
    set_conn_service(conns)
    set_portfolio_service(
        PortfolioService(connections=conns, adapter_factory=_factory())
    )
    c = TestClient(main.app)
    tok = c.post("/v1/auth/register",
                 json={"email": "a@b.com", "password": "password123"}
                 ).json()["access_token"]
    c.headers = {"Authorization": f"Bearer {tok}"}
    yield c, conns
    set_portfolio_service(PortfolioService())


def test_api_requires_auth():
    set_portfolio_service(
        PortfolioService(connections=_conns(), adapter_factory=_factory())
    )
    c = TestClient(main.app)
    assert c.get("/v1/portfolio").status_code == 401


def test_api_empty_then_with_moomoo(client):
    c, conns = client
    empty = c.get("/v1/portfolio").json()
    assert empty["summary"]["total_equity"] == 0.0
    assert empty["positions"] == []

    conns.connect(1, BrokerType.MOOMOO)
    full = c.get("/v1/portfolio").json()
    assert full["summary"]["total_equity"] == 150000.0
    assert full["summary"]["floating_pnl"] == 3260.0
    assert full["summary"]["realized_pnl"] == 0.0
    assert len(full["positions"]) == 1
    assert full["positions"][0]["broker"] == "MOOMOO"
    assert "MOOMOO" in full["brokers"]


# --- portfolio aggregates Moomoo + IBKR ------------------------------------

def _ibkr_adapter(connected=True):
    from app.brokers.adapter import IBKRAdapter
    from app.brokers.ibkr_client import MockIBKRClient
    from app.brokers.ibkr_config import IBKRConfig
    from app.brokers.ibkr_service import IBKRService
    return IBKRAdapter(service=IBKRService(
        config=IBKRConfig(trading_env="paper"),
        client=MockIBKRClient(connected=connected)))


def _both_factory(ibkr_up=True):
    def factory(bt):
        if bt == BrokerType.MOOMOO:
            return _moomoo_adapter()
        return _ibkr_adapter(connected=ibkr_up)
    return factory


def test_portfolio_aggregates_moomoo_and_ibkr():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    conns.connect(1, BrokerType.IBKR)
    svc = PortfolioService(connections=conns,
                           adapter_factory=_both_factory(ibkr_up=True))
    p = svc.for_user(1)
    assert set(p.brokers) == {"MOOMOO", "IBKR"}
    # 150k Moomoo + 75k IBKR.
    assert p.summary.total_equity == 225000.0
    brokers_in_positions = {pos.broker for pos in p.positions}
    assert brokers_in_positions == {"MOOMOO", "IBKR"}
    assert not p.errors


def test_ibkr_gateway_down_does_not_break_portfolio():
    conns = _conns()
    conns.connect(1, BrokerType.MOOMOO)
    conns.connect(1, BrokerType.IBKR)
    svc = PortfolioService(connections=conns,
                           adapter_factory=_both_factory(ibkr_up=False))
    p = svc.for_user(1)
    # Moomoo still aggregated.
    assert p.summary.total_equity == 150000.0
    assert any(pos.broker == "MOOMOO" for pos in p.positions)
    # IBKR down -> recorded as a non-fatal error.
    assert any(e.broker == "IBKR" for e in p.errors)
