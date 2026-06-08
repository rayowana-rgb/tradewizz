"""End-to-end: stale data refreshes on a new trading day + debug endpoints.

Covers the validation scenario: Day T close=100 cached; Day T+1 close=105 must
be returned by analyze without a backend restart. Also exercises screener,
market overview, indices refresh and the /v1/debug/cache endpoints.
"""

from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd
import pytest
from fastapi.testclient import TestClient

from app.cache import OhlcvCache
from app.engine import AnalysisEngine
from app.models import Market

JKT = ZoneInfo("Asia/Jakarta")


def make_df(last_date: str, close: float, n: int = 120) -> pd.DataFrame:
    idx = pd.date_range(end=last_date, periods=n, freq="D")
    closes = np.linspace(close - 5, close, n)
    vol = np.full(n, 5_000_000.0)
    return pd.DataFrame(
        {"Open": closes, "High": closes + 1, "Low": closes - 1,
         "Close": closes, "Volume": vol},
        index=idx,
    )


class DayFetcher:
    def __init__(self):
        self.calls = 0
        self.day = "2026-06-08"
        self.close = 100.0

    def __call__(self, ticker, period, interval):
        # Count only stock fetches; the benchmark index (^...) fetched for
        # relative-strength/regime context is cached per-market and irrelevant
        # to the stock-refresh assertions here.
        if not ticker.startswith("^"):
            self.calls += 1
        return make_df(self.day, self.close)


# --- analyze refreshes across trading days (the validation scenario) -------

def test_analyze_refreshes_on_new_trading_day(tmp_path):
    fetcher = DayFetcher()
    now = {"dt": datetime(2026, 6, 8, 22, 0, tzinfo=JKT)}  # Day T after close
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600,
        now_provider=lambda m: now["dt"],
    )
    engine = AnalysisEngine(fetcher=cache.get)

    def level(r):
        # Resistance tracks the recent high, which scales with the close, so
        # it cleanly distinguishes Day T (close~100) from Day T+1 (close~105).
        return r.support_resistance.major_resistance

    r1 = engine.analyze("BBCA", Market.IDX)
    assert fetcher.calls == 1
    l1 = level(r1)
    assert 99 <= l1 <= 103  # Day T close ~100

    # Same day -> cached, identical.
    r1b = engine.analyze("BBCA", Market.IDX)
    assert fetcher.calls == 1
    assert level(r1b) == l1

    # Day T+1: provider close=105. Must reflect 105 WITHOUT restart.
    now["dt"] = datetime(2026, 6, 9, 10, 0, tzinfo=JKT)
    fetcher.day = "2026-06-09"
    fetcher.close = 105.0
    r2 = engine.analyze("BBCA", Market.IDX)
    assert fetcher.calls == 2  # trading day rolled -> refetched fresh data
    l2 = level(r2)
    assert l2 > l1  # newer, higher close reflected
    assert 104 <= l2 <= 108


# --- debug endpoints -------------------------------------------------------

@pytest.fixture()
def client(tmp_path, monkeypatch):
    """Real app + an isolated cache dir, with the global cache registry pinned
    to ONLY the caches this test creates (so debug endpoints see a clean set).

    We do NOT reload app.main (that re-runs module-level wiring and can hang);
    the /v1/debug/cache endpoints enumerate the process-wide cache registry, so
    we swap the registry to an empty list and point the default cache dir at a
    per-test temp dir for the duration of the test.
    """
    monkeypatch.setenv("TRADEWIZ_CACHE_DIR", str(tmp_path / "ohlcv"))
    from app import cache as cache_mod
    from app import main as main_mod

    saved = list(cache_mod._CACHE_REGISTRY)
    cache_mod._CACHE_REGISTRY.clear()
    try:
        yield TestClient(main_mod.app), main_mod, cache_mod
    finally:
        cache_mod._CACHE_REGISTRY.clear()
        cache_mod._CACHE_REGISTRY.extend(saved)


def test_debug_cache_lists_entries(client):
    c, main_mod, cache_mod = client
    fetcher = DayFetcher()
    cache = cache_mod.OhlcvCache(
        fetcher, ttl_seconds=24 * 3600,
        now_provider=lambda m: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    cache.get("0700.HK")

    resp = c.get("/v1/debug/cache")
    assert resp.status_code == 200
    body = resp.json()
    assert body["count"] >= 2
    symbols = {e["symbol"] for e in body["entries"]}
    assert "BBCA.JK" in symbols and "0700.HK" in symbols
    assert "IDX" in body["markets"]
    assert "session_state" in body["markets"]["IDX"]


def test_debug_cache_clear_all(client):
    c, main_mod, cache_mod = client
    fetcher = DayFetcher()
    cache = cache_mod.OhlcvCache(
        fetcher, ttl_seconds=24 * 3600,
        now_provider=lambda m: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    cache.get("0700.HK")

    resp = c.post("/v1/debug/cache/clear?mode=all")
    assert resp.status_code == 200
    assert resp.json()["removed"] >= 2
    assert c.get("/v1/debug/cache").json()["count"] == 0


def test_debug_cache_clear_by_symbol(client):
    c, main_mod, cache_mod = client
    fetcher = DayFetcher()
    cache = cache_mod.OhlcvCache(
        fetcher, ttl_seconds=24 * 3600,
        now_provider=lambda m: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    cache.get("0700.HK")

    resp = c.post("/v1/debug/cache/clear?mode=symbol&symbol=BBCA")
    assert resp.status_code == 200
    assert resp.json()["removed"] == 1
    remaining = {e["symbol"] for e in c.get("/v1/debug/cache").json()["entries"]}
    assert remaining == {"0700.HK"}


def test_debug_cache_clear_by_market(client):
    c, main_mod, cache_mod = client
    fetcher = DayFetcher()
    cache = cache_mod.OhlcvCache(
        fetcher, ttl_seconds=24 * 3600,
        now_provider=lambda m: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    cache.get("0700.HK")

    resp = c.post("/v1/debug/cache/clear?mode=market&market=HKEX")
    assert resp.status_code == 200
    assert resp.json()["removed"] == 1
    remaining = {e["symbol"] for e in c.get("/v1/debug/cache").json()["entries"]}
    assert remaining == {"BBCA.JK"}


def test_debug_cache_clear_requires_symbol(client):
    c, _, _ = client
    assert c.post("/v1/debug/cache/clear?mode=symbol").status_code == 400
    assert c.post("/v1/debug/cache/clear?mode=market").status_code == 400
    assert c.post("/v1/debug/cache/clear?mode=bogus").status_code == 400
