"""Phase 6 (Offline-first snapshot) tests.

Covers:
  * SnapshotCache: get/put, TTL freshness, guarded write (Phase N), clear.
  * SnapshotService: dashboard/portfolio/watchlist aggregation; cache hit
    (no recompute) vs forced rebuild; failed/empty section keeps prior data.
  * SnapshotScheduler: cadence-gated tick refreshes the global sections.
  * /v1/snapshot/* endpoints end-to-end with real JWT auth.

No scoring/ranking/accounting is exercised here — only data delivery.
"""

from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient

import app.main as main
from app.models import Market
from app.snapshots.cache import SnapshotCache
from app.snapshots.scheduler import SnapshotScheduler
from app.snapshots.service import SnapshotService


# --------------------------------------------------------------------------- #
# SnapshotCache
# --------------------------------------------------------------------------- #
def test_cache_put_get_and_age(tmp_path):
    t = {"now": 1000.0}
    c = SnapshotCache(directory=str(tmp_path), clock=lambda: t["now"])
    c.put("dashboard", {"k": 1})
    payload, age = c.get("dashboard")
    assert payload == {"k": 1}
    assert age == 0.0
    t["now"] = 1030.0
    _, age2 = c.get("dashboard")
    assert age2 == 30.0


def test_cache_ttl_freshness(tmp_path):
    t = {"now": 0.0}
    c = SnapshotCache(directory=str(tmp_path), clock=lambda: t["now"])
    c.put("indices", {"indices": []})
    assert c.is_fresh("indices", ttl=60) is True
    t["now"] = 61.0
    assert c.is_fresh("indices", ttl=60) is False


def test_cache_guarded_never_overwrites_with_empty(tmp_path):
    c = SnapshotCache(directory=str(tmp_path))
    assert c.put_guarded("rotation", {"best_market": "US"}) is True
    # None / {} / [] / error must NOT overwrite the good snapshot.
    assert c.put_guarded("rotation", None) is False
    assert c.put_guarded("rotation", {}) is False
    assert c.put_guarded("rotation", []) is False
    assert c.put_guarded("rotation", {"error": "boom"}) is False
    payload, _ = c.get("rotation")
    assert payload == {"best_market": "US"}


def test_cache_persists_across_instances(tmp_path):
    c1 = SnapshotCache(directory=str(tmp_path))
    c1.put("dashboard", {"v": 7})
    c2 = SnapshotCache(directory=str(tmp_path))
    payload, _ = c2.get("dashboard")
    assert payload == {"v": 7}


def test_cache_clear(tmp_path):
    c = SnapshotCache(directory=str(tmp_path))
    c.put("a", {"x": 1})
    c.put("b", {"y": 2})
    c.clear("a")
    assert c.has("a") is False
    assert c.has("b") is True
    c.clear()
    assert c.has("b") is False


# --------------------------------------------------------------------------- #
# SnapshotService — fakes that count calls
# --------------------------------------------------------------------------- #
class _Counter:
    def __init__(self, value):
        self.value = value
        self.calls = 0

    def __call__(self, *a, **k):
        self.calls += 1
        return self.value


class _Brief:
    def __init__(self):
        self.calls = 0

    def __call__(self, market):
        self.calls += 1
        return {"market": market.value, "headline": "hi"}


def _service(tmp_path, clock):
    cache = SnapshotCache(directory=str(tmp_path), clock=clock)
    indices = _Counter([{"symbol": "^GSPC", "price": 5000}])
    rotation = _Counter({"best_market": "US", "markets": []})
    radar = _Counter({"opportunities": [{"symbol": "NVDA"}]})
    daily = _Counter({"picks": [{"symbol": "AAPL"}]})
    multibagger = _Counter({"candidates": []})
    watchlist = _Counter({"suggestions": [{"symbol": "MSFT"}]})

    def notifications(uid):
        return ([{"id": 1, "title": "t"}], 1)

    svc = SnapshotService(
        cache=cache,
        indices_provider=indices,
        brief_provider=_Brief(),
        rotation_provider=rotation,
        opportunities_provider=radar,
        daily_provider=daily,
        multibagger_provider=multibagger,
        watchlist_provider=lambda uid, ex: watchlist(),
        notifications_provider=notifications,
        account_provider=lambda uid: {"cash": 1000},
        positions_provider=lambda uid: [{"symbol": "NVDA", "qty": 1}],
        health_provider=lambda uid: {"score": 80},
        quality_provider=lambda uid: [{"symbol": "NVDA", "grade": "A"}],
        manager_provider=lambda uid: {"risk_level": "LOW"},
    )
    return svc, {
        "indices": indices, "rotation": rotation, "radar": radar,
        "daily": daily, "multibagger": multibagger, "watchlist": watchlist,
    }


def test_dashboard_aggregates_all_sections(tmp_path):
    svc, _ = _service(tmp_path, clock=lambda: 0.0)
    snap = svc.dashboard(Market.US)
    d = snap.model_dump()
    assert d["market"] == "US"
    assert d["indices"]["indices"][0]["symbol"] == "^GSPC"
    assert d["morning_brief"]["headline"] == "hi"
    assert d["rotation"]["best_market"] == "US"
    assert d["radar"]["opportunities"][0]["symbol"] == "NVDA"
    assert d["daily_picks"]["picks"][0]["symbol"] == "AAPL"
    assert d["watchlist_ai"]["suggestions"][0]["symbol"] == "MSFT"
    assert d["notifications"]["unread_count"] == 1
    assert "indices" in d["section_ages"]


def test_dashboard_cache_hit_avoids_recompute(tmp_path):
    t = {"now": 0.0}
    svc, counters = _service(tmp_path, clock=lambda: t["now"])
    svc.dashboard(Market.US)
    assert counters["rotation"].calls == 1
    assert counters["indices"].calls == 1
    # Within all TTLs: a second build recomputes nothing (pure cache hit).
    t["now"] = 30.0
    svc.dashboard(Market.US)
    assert counters["rotation"].calls == 1
    assert counters["indices"].calls == 1
    # Past the indices TTL (1m) only indices is rebuilt; rotation (15m) stays.
    t["now"] = 200.0
    svc.dashboard(Market.US)
    assert counters["indices"].calls == 2
    assert counters["rotation"].calls == 1


def test_dashboard_force_rebuilds(tmp_path):
    t = {"now": 0.0}
    svc, counters = _service(tmp_path, clock=lambda: t["now"])
    svc.dashboard(Market.US)
    svc.dashboard(Market.US, force=True)
    assert counters["rotation"].calls == 2
    assert counters["indices"].calls == 2


def test_failed_section_keeps_previous(tmp_path):
    t = {"now": 0.0}
    cache = SnapshotCache(directory=str(tmp_path), clock=lambda: t["now"])
    good = {"best_market": "US"}
    state = {"fail": False}

    def rotation():
        if state["fail"]:
            raise RuntimeError("yahoo down")
        return good

    svc = SnapshotService(cache=cache, rotation_provider=rotation)
    s1 = svc.dashboard(Market.US)
    assert s1.rotation == good
    # Backend now fails AND TTL elapsed -> previous good snapshot is kept.
    state["fail"] = True
    t["now"] = 10_000.0
    s2 = svc.dashboard(Market.US)
    assert s2.rotation == good


def test_portfolio_snapshot(tmp_path):
    svc, _ = _service(tmp_path, clock=lambda: 0.0)
    snap = svc.portfolio(42)
    d = snap.model_dump()
    assert d["account"]["cash"] == 1000
    assert d["positions"][0]["symbol"] == "NVDA"
    assert d["portfolio_health"]["score"] == 80
    assert d["portfolio_quality"][0]["grade"] == "A"
    assert d["portfolio_manager"]["risk_level"] == "LOW"


def test_watchlist_snapshot(tmp_path):
    svc, _ = _service(tmp_path, clock=lambda: 0.0)
    snap = svc.watchlist(7, Market.US, existing=["US:AAPL"])
    d = snap.model_dump()
    assert d["watchlist_ai"][0]["symbol"] == "MSFT"
    assert d["rotation"]["best_market"] == "US"
    assert d["daily_picks"][0]["symbol"] == "AAPL"


# --------------------------------------------------------------------------- #
# Scheduler
# --------------------------------------------------------------------------- #
def test_scheduler_tick_refreshes_on_cadence(tmp_path):
    t = {"now": 0.0}
    svc, counters = _service(tmp_path, clock=lambda: t["now"])
    sched = SnapshotScheduler(svc, markets=[Market.US])

    ran = sched.tick(now=0.0)
    # First tick runs the per-section tasks AND the hourly market_open build.
    assert "indices" in ran and "rotation" in ran and "radar" in ran
    assert "market_open" in ran
    assert counters["rotation"].calls >= 1

    rot_before = counters["rotation"].calls
    idx_before = counters["indices"].calls

    # 30s later: nothing is due yet (shortest cadence is 1m).
    assert sched.tick(now=30.0) == []
    assert counters["indices"].calls == idx_before

    # 61s: only indices (1m cadence) is due.
    ran = sched.tick(now=61.0)
    assert ran == ["indices"]
    assert counters["indices"].calls == idx_before + 1
    assert counters["rotation"].calls == rot_before

    # 16m: rotation + radar (15m) due again, plus indices.
    ran = sched.tick(now=16 * 60.0)
    assert "rotation" in ran and "radar" in ran and "indices" in ran


def test_scheduler_start_stop_idempotent(tmp_path):
    svc, _ = _service(tmp_path, clock=lambda: 0.0)
    sched = SnapshotScheduler(svc, tick_seconds=0.01)
    sched.start()
    sched.start()  # idempotent
    sched.stop()
    sched.stop()  # idempotent


# --------------------------------------------------------------------------- #
# Endpoints end-to-end (real JWT auth)
# --------------------------------------------------------------------------- #
@pytest.fixture()
def client(tmp_path):
    from app.snapshots import router as snap_router

    svc, _ = _service(tmp_path, clock=lambda: 0.0)
    snap_router.set_service(svc)
    c = TestClient(main.app)
    yield c


def _register(c) -> dict:
    email = f"snap_{uuid.uuid4().hex[:8]}@example.com"
    r = c.post("/v1/auth/register",
               json={"email": email, "password": "Passw0rd!!"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def test_dashboard_endpoint_requires_auth():
    c = TestClient(main.app)
    assert c.get("/v1/snapshot/dashboard?market=US").status_code == 401


def test_dashboard_endpoint(client):
    h = _register(client)
    r = client.get("/v1/snapshot/dashboard?market=US", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["market"] == "US"
    assert body["rotation"]["best_market"] == "US"
    assert body["generated_at"]


def test_portfolio_endpoint(client):
    h = _register(client)
    r = client.get("/v1/snapshot/portfolio", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["account"]["cash"] == 1000


def test_watchlist_endpoint(client):
    h = _register(client)
    r = client.get("/v1/snapshot/watchlist?market=US", headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["rotation"]["best_market"] == "US"


def test_force_query_rebuilds_endpoint(client):
    h = _register(client)
    r = client.get("/v1/snapshot/dashboard?market=US&force=true", headers=h)
    assert r.status_code == 200, r.text
