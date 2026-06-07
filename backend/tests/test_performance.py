"""Portfolio performance analytics tests (no network)."""

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
from app.brokers.ibkr_client import MockIBKRClient
from app.brokers.ibkr_config import IBKRConfig
from app.brokers.ibkr_service import IBKRService
from app.brokers.models import BrokerType
from app.brokers.service import BrokerConnectionService
from app.brokers.store import InMemoryConnectionStore
from app.portfolio.performance import (
    NO_HISTORY_NOTE,
    REALIZED_PNL_NOTE,
    PerformanceService,
)
from app.portfolio.router import (
    set_performance_service,
    set_service as set_portfolio_service,
)
from app.portfolio.service import PortfolioService
from app.portfolio.store import InMemorySnapshotStore


def _moomoo():
    return MoomooAdapter(service=BrokerService(
        config=BrokerConfig(trading_env="paper"), client=MockBrokerClient()))


def _ibkr():
    return IBKRAdapter(service=IBKRService(
        config=IBKRConfig(trading_env="paper"), client=MockIBKRClient()))


def _perf(brokers=("MOOMOO",)):
    conns = BrokerConnectionService(store=InMemoryConnectionStore())
    for b in brokers:
        conns.connect(1, BrokerType[b])

    def factory(bt):
        return _moomoo() if bt == BrokerType.MOOMOO else _ibkr()

    pf = PortfolioService(connections=conns, adapter_factory=factory)
    store = InMemorySnapshotStore()
    return PerformanceService(portfolio=pf, store=store), store


# --- snapshot ---------------------------------------------------------------

def test_snapshot_creation_stores_current_portfolio():
    svc, store = _perf()
    snap = svc.create_snapshot(1)
    assert snap.id == 1
    assert snap.total_equity == 150000.0  # moomoo only
    assert len(store.list_for_user(1)) == 1


# --- performance: no snapshots ----------------------------------------------

def test_performance_no_snapshots():
    svc, _ = _perf()
    r = svc.performance(1)
    assert r.total_equity == 150000.0
    assert r.equity_curve == []
    assert r.daily_pnl == 0.0
    assert NO_HISTORY_NOTE in r.notes


def test_performance_total_pnl_is_floating_plus_realized():
    svc, _ = _perf()
    r = svc.performance(1)
    assert r.total_pnl == round(r.floating_pnl + r.realized_pnl, 2)


# --- performance: with snapshots --------------------------------------------

def test_performance_with_snapshots_builds_equity_curve():
    svc, store = _perf()
    store.create(1, 140000.0, 100000.0, 40000.0, 2000.0, 0.0,
                 timestamp="2026-06-06T12:00:00+00:00")
    svc.create_snapshot(1)
    r = svc.performance(1)
    assert len(r.equity_curve) == 2
    assert NO_HISTORY_NOTE not in r.notes


def test_daily_pnl_uses_yesterdays_baseline():
    svc, store = _perf()
    # Baseline taken yesterday at 140k; current equity is 150k -> +10k.
    store.create(1, 140000.0, 100000.0, 40000.0, 2000.0, 0.0,
                 timestamp="2026-06-06T12:00:00+00:00")
    r = svc.performance(1)
    assert r.daily_pnl == 10000.0
    assert r.daily_pnl_percent == round(10000.0 / 140000.0 * 100, 2)


# --- breakdowns -------------------------------------------------------------

def test_broker_breakdown():
    svc, _ = _perf(brokers=("MOOMOO", "IBKR"))
    r = svc.performance(1)
    brokers = {b.broker for b in r.broker_breakdown}
    assert brokers == {"MOOMOO", "IBKR"}
    moomoo = next(b for b in r.broker_breakdown if b.broker == "MOOMOO")
    assert moomoo.floating_pnl == 3260.0


def test_asset_breakdown_includes_cash():
    svc, _ = _perf()
    r = svc.performance(1)
    assets = {a.asset for a in r.asset_breakdown}
    assert "Cash" in assets
    assert "HKEX" in assets


# --- winners / losers -------------------------------------------------------

def test_top_winners_and_losers():
    svc, _ = _perf(brokers=("MOOMOO", "IBKR"))
    r = svc.performance(1)
    # Moomoo HK.00700 is a winner (+3260); no losers in the mock data.
    assert any(w.symbol == "HK.00700" for w in r.top_winners)
    assert all(w.unrealized_pnl > 0 for w in r.top_winners)
    assert all(l.unrealized_pnl < 0 for l in r.top_losers)


def test_winner_percent_computed_from_cost_basis():
    svc, _ = _perf()
    r = svc.performance(1)
    w = next(w for w in r.top_winners if w.symbol == "HK.00700")
    # cost basis = 380 * 100 = 38000; pnl 3260 -> ~8.58%.
    assert abs(w.unrealized_pnl_percent - 8.58) < 0.01


# --- realized P/L safety ----------------------------------------------------

def test_missing_realized_pnl_handled_with_note():
    svc, _ = _perf()
    r = svc.performance(1)
    assert r.realized_pnl == 0.0  # never fabricated
    assert REALIZED_PNL_NOTE in r.notes


# --- API (auth-scoped) ------------------------------------------------------

@pytest.fixture()
def client():
    auth = AuthService(config=AuthConfig(jwt_secret="t"),
                       store=InMemoryUserStore())
    perf, _ = _perf(brokers=("MOOMOO",))
    set_auth_service(auth)
    set_portfolio_service(perf._portfolio)
    set_performance_service(perf)
    c = TestClient(main.app)
    tok = c.post("/v1/auth/register",
                 json={"email": "a@b.com", "password": "password123"}
                 ).json()["access_token"]
    c.headers = {"Authorization": f"Bearer {tok}"}
    yield c
    set_performance_service(PerformanceService())


def test_api_performance_requires_auth():
    set_performance_service(_perf()[0])
    c = TestClient(main.app)
    assert c.get("/v1/portfolio/performance").status_code == 401
    assert c.post("/v1/portfolio/snapshot").status_code == 401


def test_api_snapshot_then_performance(client):
    snap = client.post("/v1/portfolio/snapshot")
    assert snap.status_code == 200
    assert snap.json()["total_equity"] == 150000.0

    perf = client.get("/v1/portfolio/performance").json()
    assert perf["total_equity"] == 150000.0
    assert "broker_breakdown" in perf
    assert "top_winners" in perf
    assert "equity_curve" in perf
    assert len(perf["equity_curve"]) == 1
