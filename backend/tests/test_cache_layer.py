"""Cache layer tests (Morning Brief / Rotation / Radar + shared infra).

Covers:
  * TTLCache get/set/expiry (injectable timer, no sleeping).
  * CacheManager hit/miss counters + stampede protection (single rebuild).
  * Morning Brief: first call miss, second hit, TTL expiry rebuilds, per-market
    isolation, response carries ``cached=True`` only on a hit.
  * Rotation: cache hit/miss, one failing market does not break the response.
  * Radar: cached response reused, engine.screen() not called again in TTL.
  * GET /v1/system/cache metrics increment.

Caching only memoizes existing read-only output; scoring/accounting/ranking and
API schemas are unchanged.
"""

from __future__ import annotations

import threading

from fastapi.testclient import TestClient

import app.main as main
from app.cache_layer.cache_manager import CacheManager as _CM
from app.cache_layer.ttl_cache import TTLCache
from app.system import router as system_router
from app.models import Market, ScreenerMatch, ScreenerResult
from app.morning_brief.service import MorningBriefService
from app.radar.service import RadarService
from app.rotation.service import GlobalRotationService


# --- fixtures ---------------------------------------------------------------
class _Clock:
    def __init__(self, t: float = 0.0):
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, dt: float) -> None:
        self.t += dt


def _match(symbol, score, change=2.0, value=3e9, signal="BUY"):
    return ScreenerMatch(
        symbol=symbol, name=symbol, score=score, signal=signal, price=100.0,
        change_percent=change, categories=[], value_traded=value,
    )


def _us():
    return [_match("NVDA", 94, 6.0, 8e9), _match("PLTR", 91, 5.0, 5e9),
            _match("AAPL", 88), _match("META", 60, 0.2, 5e8)]


def _idx():
    return [_match("BBCA", 90, 3.0, 2e9), _match("TPIA", 63, -1.0, 8e8,
            signal="HOLD")]


class _CountingProvider:
    """Screen provider that records how many times engine.screen() ran."""

    def __init__(self, fail_markets=None):
        self.calls = []  # list of markets screened
        self._fail = set(fail_markets or [])

    def __call__(self, market, limit=50, min_score=0.0, min_value_traded=0.0):
        self.calls.append(market)
        if market in self._fail:
            raise RuntimeError(f"{market.value} screen failed (simulated)")
        data = {Market.US: _us(), Market.IDX: _idx()}.get(market, [])
        return ScreenerResult(market=market, matches=data[:limit],
                              generated_at="2026-06-09T00:00:00Z")


def _radar(provider, markets, cache):
    return RadarService(provider, markets=markets, cache=cache)


# === TTLCache ==============================================================
def test_ttl_cache_get_set_and_expiry():
    clock = _Clock()
    cache = TTLCache(ttl=10.0, timer=clock)
    assert cache.get("k") is None
    cache.set("k", 123)
    assert cache.get("k") == 123
    clock.advance(9.9)
    assert cache.get("k") == 123      # still live
    clock.advance(0.2)                # now past ttl
    assert cache.get("k") is None     # expired


# === CacheManager ==========================================================
def test_manager_hit_miss_counters():
    mgr = _CM()
    calls = []
    v, cached = mgr.get_or_build("radar", "k", lambda: (calls.append(1), 7)[1])
    assert v == 7 and cached is False
    v, cached = mgr.get_or_build("radar", "k", lambda: (calls.append(1), 9)[1])
    assert v == 7 and cached is True  # served from cache, builder not run
    assert len(calls) == 1
    m = mgr.metrics()
    assert m["radar_misses"] == 1
    assert m["radar_hits"] == 1


def test_manager_stampede_only_one_rebuild():
    mgr = _CM()
    build_count = {"n": 0}
    start = threading.Barrier(8)
    gate = threading.Event()

    def builder():
        build_count["n"] += 1
        gate.wait(timeout=2)
        return "VALUE"

    results = []

    def worker():
        start.wait()
        v, _ = mgr.get_or_build("rotation", "key", builder)
        results.append(v)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    # Let the first builder enter, then release.
    threading.Timer(0.2, gate.set).start()
    for t in threads:
        t.join(timeout=3)

    assert build_count["n"] == 1            # only ONE rebuild
    assert results == ["VALUE"] * 8         # everyone got the same value
    m = mgr.metrics()
    assert m["rotation_misses"] == 1
    assert m["rotation_hits"] == 7


# === Morning Brief =========================================================
def test_morning_brief_first_miss_second_hit():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US, Market.IDX], mgr)
    svc = MorningBriefService(radar=radar, cache=mgr)

    first = svc.brief(Market.US)
    assert first.cached is False
    n_after_first = len(prov.calls)
    assert n_after_first > 0

    second = svc.brief(Market.US)
    assert second.cached is True
    # No further engine.screen() calls on the cache hit.
    assert len(prov.calls) == n_after_first

    m = mgr.metrics()
    assert m["morning_brief_hits"] == 1
    assert m["morning_brief_misses"] == 1


def test_morning_brief_cache_expiry_rebuilds():
    clock = _Clock()
    mgr = _CM()
    # Force the morning_brief namespace onto our injectable clock.
    mgr._ns["morning_brief"].cache = TTLCache(ttl=15 * 60, timer=clock)
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US], mgr)
    # Radar namespace also on the clock so its 5-min TTL expires too.
    mgr._ns["radar"].cache = TTLCache(ttl=5 * 60, timer=clock)
    svc = MorningBriefService(radar=radar, cache=mgr)

    svc.brief(Market.US)                       # miss (build)
    assert svc.brief(Market.US).cached is True  # hit
    clock.advance(15 * 60 + 1)                 # past 15-min TTL
    rebuilt = svc.brief(Market.US)
    assert rebuilt.cached is False             # rebuilt after expiry
    assert mgr.metrics()["morning_brief_misses"] == 2


def test_morning_brief_per_market_isolation():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US, Market.IDX], mgr)
    svc = MorningBriefService(radar=radar, cache=mgr)

    us = svc.brief(Market.US)
    idx = svc.brief(Market.IDX)
    assert us.market == Market.US
    assert idx.market == Market.IDX
    # Two distinct misses (one per market).
    assert mgr.metrics()["morning_brief_misses"] == 2
    # Re-fetching each is a hit; caches are isolated by market.
    assert svc.brief(Market.US).cached is True
    assert svc.brief(Market.IDX).cached is True


# === Rotation ==============================================================
def test_rotation_cache_hit_and_miss():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US, Market.IDX], mgr)
    svc = GlobalRotationService(radar=radar,
                                markets=[Market.US, Market.IDX], cache=mgr)

    first = svc.global_rotation()
    assert first.cached is False
    assert first.best_market in ("US", "IDX")
    calls_after = len(prov.calls)

    second = svc.global_rotation()
    assert second.cached is True
    assert len(prov.calls) == calls_after   # no rescreen on hit
    m = mgr.metrics()
    assert m["rotation_hits"] == 1
    assert m["rotation_misses"] == 1


def test_rotation_one_market_failure_does_not_break_response():
    mgr = _CM()
    # US screening raises; rotation must still return IDX.
    prov = _CountingProvider(fail_markets=[Market.US])
    radar = _radar(prov, [Market.US, Market.IDX], mgr)
    svc = GlobalRotationService(radar=radar,
                                markets=[Market.US, Market.IDX], cache=mgr)

    resp = svc.global_rotation()
    returned = {r.market for r in resp.markets}
    assert Market.IDX in returned       # surviving market present
    # US produced no opportunities (screen failed) -> rotation_score 0, but it
    # never raised a 500.
    assert resp.best_market == "IDX"


# === Radar =================================================================
def test_radar_cached_response_no_rescreen_in_ttl():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US, Market.IDX], mgr)

    first = radar.opportunities()
    assert first.cached is False
    calls_after_first = len(prov.calls)
    assert calls_after_first > 0       # engine.screen() ran

    second = radar.opportunities()
    assert second.cached is True
    # engine.screen() NOT called again within the TTL.
    assert len(prov.calls) == calls_after_first


def test_radar_per_market_scan_cached_across_methods():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US, Market.IDX], mgr)

    radar.opportunities()              # warms per-market radar caches
    calls = len(prov.calls)
    # daily() reuses the same per-market scans -> no new engine.screen().
    radar.daily()
    radar.multibagger()
    assert len(prov.calls) == calls
    assert mgr.metrics()["radar_hits"] >= 1


def test_radar_market_top_is_cached():
    mgr = _CM()
    prov = _CountingProvider()
    radar = _radar(prov, [Market.US], mgr)
    a = radar.market_top(Market.US)
    calls = len(prov.calls)
    b = radar.market_top(Market.US)
    assert [o.symbol for o in a] == [o.symbol for o in b]
    assert len(prov.calls) == calls    # second call served from cache


# === Cache monitoring endpoint =============================================
def test_system_cache_endpoint_reports_metrics():
    mgr = _CM()
    # Drive a couple of misses + hits through the manager.
    mgr.get_or_build("morning_brief", "k", lambda: 1)   # miss
    mgr.get_or_build("morning_brief", "k", lambda: 1)   # hit
    mgr.get_or_build("radar", "r", lambda: 2)           # miss
    mgr.get_or_build("rotation", "g", lambda: 3)        # miss

    system_router.set_cache_manager(mgr)
    try:
        client = TestClient(main.app)
        resp = client.get("/v1/system/cache")
        assert resp.status_code == 200          # no auth required
        body = resp.json()
        assert body["morning_brief_hits"] == 1
        assert body["morning_brief_misses"] == 1
        assert body["radar_misses"] == 1
        assert body["rotation_misses"] == 1
    finally:
        # Restore the live singleton so other tests are unaffected.
        from app.cache_layer import get_cache_manager
        system_router.set_cache_manager(get_cache_manager())
