"""Multi-broker connection framework tests (no network, in-memory stores)."""

import pytest
from fastapi.testclient import TestClient

from app import main
from app.auth.config import AuthConfig
from app.auth.router import set_service as set_auth_service
from app.auth.service import AuthService
from app.auth.store import InMemoryUserStore
from app.brokers.adapter import (
    BrokerNotImplemented,
    IBKRAdapter,
    MoomooAdapter,
    make_adapter,
)
from app.brokers.models import BrokerType
from app.brokers.router import set_service as set_conn_service
from app.brokers.service import BrokerConnectionService, ConnectionError_
from app.brokers.store import InMemoryConnectionStore


# --- service ----------------------------------------------------------------

def _svc():
    return BrokerConnectionService(store=InMemoryConnectionStore())


def test_connect_moomoo_creates_active_connection():
    svc = _svc()
    conn = svc.connect(1, BrokerType.MOOMOO)
    assert conn.broker_type == BrokerType.MOOMOO
    assert conn.is_active is True
    assert conn.display_name == "Moomoo"
    assert svc.count_active(1) == 1


def test_connect_custom_display_name():
    svc = _svc()
    conn = svc.connect(1, BrokerType.MOOMOO, display_name="My Paper Acct")
    assert conn.display_name == "My Paper Acct"


def test_connect_ibkr_is_enabled():
    # IBKR is now an implemented broker -> connecting succeeds.
    svc = _svc()
    conn = svc.connect(1, BrokerType.IBKR)
    assert conn.broker_type == BrokerType.IBKR
    assert conn.is_active is True
    assert svc.count_active(1) == 1


def test_duplicate_active_connection_rejected():
    svc = _svc()
    svc.connect(1, BrokerType.MOOMOO)
    with pytest.raises(ConnectionError_) as ei:
        svc.connect(1, BrokerType.MOOMOO)
    assert ei.value.status_code == 409


def test_connections_are_per_user():
    svc = _svc()
    svc.connect(1, BrokerType.MOOMOO)
    svc.connect(2, BrokerType.MOOMOO)
    assert svc.count_active(1) == 1
    assert svc.count_active(2) == 1
    assert len(svc.list(1)) == 1


def test_disconnect_removes_connection():
    svc = _svc()
    conn = svc.connect(1, BrokerType.MOOMOO)
    res = svc.disconnect(1, conn.id)
    assert res.disconnected is True
    assert svc.count_active(1) == 0


def test_disconnect_other_users_connection_404():
    svc = _svc()
    conn = svc.connect(1, BrokerType.MOOMOO)
    with pytest.raises(ConnectionError_) as ei:
        svc.disconnect(2, conn.id)  # user 2 cannot delete user 1's connection
    assert ei.value.status_code == 404


def test_disconnect_unknown_id_404():
    svc = _svc()
    with pytest.raises(ConnectionError_) as ei:
        svc.disconnect(1, 999)
    assert ei.value.status_code == 404


# --- adapters ---------------------------------------------------------------

def test_make_adapter_returns_correct_type():
    assert make_adapter(BrokerType.MOOMOO).broker_type == BrokerType.MOOMOO
    assert make_adapter(BrokerType.IBKR).broker_type == BrokerType.IBKR


def test_moomoo_adapter_delegates_to_service():
    class FakeService:
        def account(self):
            return "ACCT"

        def positions(self):
            return "POS"

        def orders(self):
            return "ORD"

        def cancel(self, oid):
            return f"CANCEL:{oid}"

    a = MoomooAdapter(service=FakeService())
    assert a.account() == "ACCT"
    assert a.positions() == "POS"
    assert a.orders() == "ORD"
    assert a.cancel_order("X") == "CANCEL:X"


def test_ibkr_adapter_is_live_and_delegates():
    # IBKR adapter now delegates to a service (no longer a NotImplemented stub).
    from app.brokers.ibkr_client import MockIBKRClient
    from app.brokers.ibkr_config import IBKRConfig
    from app.brokers.ibkr_service import IBKRService

    a = IBKRAdapter(service=IBKRService(
        config=IBKRConfig(trading_env="paper"), client=MockIBKRClient()))
    assert a.account().connected is True
    assert a.positions().positions  # has mock positions
    assert a.status().trading_env == "PAPER"


# --- API (auth-scoped) ------------------------------------------------------

@pytest.fixture()
def client():
    auth = AuthService(config=AuthConfig(jwt_secret="t"),
                       store=InMemoryUserStore())
    conn = BrokerConnectionService(store=InMemoryConnectionStore())
    auth.set_broker_count_provider(lambda uid: conn.count_active(uid))
    set_auth_service(auth)
    set_conn_service(conn)
    c = TestClient(main.app)
    tok = c.post("/v1/auth/register",
                 json={"email": "a@b.com", "password": "password123"}
                 ).json()["access_token"]
    c.headers = {"Authorization": f"Bearer {tok}"}
    yield c
    # reset
    set_auth_service(AuthService(config=AuthConfig(jwt_secret="t"),
                                 store=InMemoryUserStore()))
    set_conn_service(BrokerConnectionService(store=InMemoryConnectionStore()))


def test_api_list_connect_disconnect(client):
    assert client.get("/v1/brokers").json()["connections"] == []
    r = client.post("/v1/brokers/connect", json={"broker_type": "MOOMOO"})
    assert r.status_code == 200
    cid = r.json()["id"]
    assert len(client.get("/v1/brokers").json()["connections"]) == 1
    d = client.delete(f"/v1/brokers/{cid}")
    assert d.status_code == 200 and d.json()["disconnected"] is True


def test_api_connect_ibkr_enabled(client):
    # IBKR connect now succeeds (broker is implemented).
    r = client.post("/v1/brokers/connect", json={"broker_type": "IBKR"})
    assert r.status_code == 200
    assert r.json()["broker_type"] == "IBKR"


def test_api_requires_auth():
    set_auth_service(AuthService(config=AuthConfig(jwt_secret="t"),
                                 store=InMemoryUserStore()))
    set_conn_service(BrokerConnectionService(store=InMemoryConnectionStore()))
    c = TestClient(main.app)
    assert c.get("/v1/brokers").status_code == 401
    assert c.post("/v1/brokers/connect",
                  json={"broker_type": "MOOMOO"}).status_code == 401


def test_api_connected_brokers_count_in_profile(client):
    client.post("/v1/brokers/connect", json={"broker_type": "MOOMOO"})
    me = client.get("/v1/auth/me")
    assert me.json()["connected_brokers"] == 1
