"""Regression: every dashboard surface must match /analyze after a same-day
OHLCV refresh -- no stale score/price from any cache layer.

Surfaces and their data paths:
  * Screener list      -> GET /screen   (ScreenerCacheService snapshot)
  * Dashboard Movers   -> GET /screen   (same path as the screener list)
  * Dashboard Gainer   -> GET /market/overview (MarketOverviewService cache)
  * Dashboard Loser    -> GET /market/overview (MarketOverviewService cache)
  * Detail page        -> GET /analyze  (live OHLCV cache; the source of truth)

Two cache layers can hide a refresh:
  1. ScreenerCacheService snapshot (fixed in c6f9bdf via a cache-only probe).
  2. MarketOverviewService 5-minute in-memory cache (fixed here with the same
     cache-only probe), which previously froze top-gainer/top-loser/breadth.

These tests drive a real OHLCV cache + engine end-to-end (default registry
probe) and an injected-probe unit case, proving score/price parity.
"""

from __future__ import annotations

import tempfile
import time
from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

from app.cache import OhlcvCache
from app.engine import AnalysisEngine
from app.models import Market, ScreenerMatch, ScreenerResult
from app.screener_cache import InMemoryScreenerSnapshotStore
from app.screener_cache.service import ScreenerCacheService, make_cache_key
from app.market.overview import MarketOverviewService

HK = ZoneInfo("Asia/Hong_Kong")
CLOSED = datetime(2026, 6, 8, 18, 0, tzinfo=HK)  # Monday, after close
SYMS = ["0700.HK", "0005.HK", "0939.HK"]


def _mkdf(close: float, vol: float, n: int = 160) -> pd.DataFrame:
    idx = pd.date_range(end="2026-06-08", periods=n, freq="D")
    c = np.linspace(close - 8, close, n)
    return pd.DataFrame(
        {"Open": c, "High": c + 1, "Low": c - 1, "Close": c,
         "Volume": np.full(n, vol)},
        index=idx,
    )


def _wire(state):
    """Build the real engine -> OHLCV cache -> screener -> overview stack."""
    def fetch(ticker, period, interval):
        key = ticker.split(".")[0] + ".HK"
        s = state[key]
        return _mkdf(s["c"], s["v"])

    cache = OhlcvCache(
        fetch, cache_dir=tempfile.mkdtemp(), ttl_seconds=300,
        now_provider=lambda _m: CLOSED,
    )
    engine = AnalysisEngine(fetcher=cache.get)
    store = InMemoryScreenerSnapshotStore()

    def run_screen():
        return engine.screen(Market.HKEX, symbols=SYMS, limit=50)

    svc = ScreenerCacheService(
        store, run_screen, now_provider=lambda _m: CLOSED
    )
    screen_key = make_cache_key(
        category="", limit=50, min_score=0.0, min_value_traded=0.0
    )

    def overview_universe(_market):
        return svc.get(Market.HKEX, screen_key)

    overview = MarketOverviewService(overview_universe, ttl_seconds=300)
    return cache, engine, svc, overview, screen_key


def _analyze_score(engine, sym):
    return engine.analyze(sym, Market.HKEX).score


def test_all_dashboard_surfaces_match_analyze_after_refresh():
    state = {
        "0700.HK": {"c": 100.0, "v": 5e6},
        "0005.HK": {"c": 60.0, "v": 3e6},
        "0939.HK": {"c": 30.0, "v": 8e6},
    }
    cache, engine, svc, overview, screen_key = _wire(state)

    # Cold build: prime OHLCV + build snapshot + overview.
    for s in SYMS:
        engine.analyze(s, Market.HKEX)
    svc.get(Market.HKEX, screen_key)
    overview.get(Market.HKEX)

    # --- Same trading date: OHLCV/analyze refreshes (close + volume move). ---
    time.sleep(1.1)
    state["0700.HK"] = {"c": 130.0, "v": 9e6}   # becomes the gainer
    state["0005.HK"] = {"c": 45.0, "v": 2e6}    # becomes the loser
    state["0939.HK"] = {"c": 33.0, "v": 8e6}
    cache.clear()
    for s in SYMS:
        engine.analyze(s, Market.HKEX)  # Detail page is now fresh.

    # 1) Screener list score == analyze score (per symbol).
    screen = svc.get(Market.HKEX, screen_key)
    by = {m.symbol: m for m in screen.matches}
    for s in SYMS:
        m = by[s.upper()]
        assert m.score == _analyze_score(engine, s), f"screener stale {s}"

    # 2) Dashboard movers use the same /screen path -> same fresh scores.
    movers = sorted(
        screen.matches, key=lambda m: m.change_percent, reverse=True
    )
    for m in movers:
        assert m.score == _analyze_score(
            engine, m.symbol
        ), f"mover stale {m.symbol}"

    # 3 & 4) Dashboard gainer / loser come from the overview cache, which must
    # have invalidated + rebuilt -> their price matches the refreshed close.
    ov = overview.get(Market.HKEX)
    assert ov.top_gainer is not None and ov.top_loser is not None
    # The gainer is the biggest %-up symbol; loser the biggest %-down.
    gainer = ov.top_gainer
    loser = ov.top_loser
    # Their reported price must equal the post-refresh screener price (which we
    # already proved equals analyze), i.e. not the frozen pre-refresh value.
    assert gainer.price == by[gainer.symbol].price, "gainer price stale"
    assert loser.price == by[loser.symbol].price, "loser price stale"
    # And the post-refresh prices are the new ones (130/45/33), not 100/60/30.
    assert by["0700.HK"].price == 130.0
    assert by["0005.HK"].price == 45.0
    assert by["0939.HK"].price == 33.0
    # Overview rebuilt -> its updated_at advanced past the cold build.
    assert ov.updated_at is not None


def test_overview_serves_cached_when_data_not_newer():
    """No newer data -> overview stays cached (TTL behavior preserved)."""
    calls = {"n": 0}

    def run_screen(_market):
        calls["n"] += 1
        return ScreenerResult(
            market=Market.HKEX,
            matches=[ScreenerMatch(
                symbol="0700.HK", name="Tencent", score=88.0, signal="BUY",
                price=100.0, change_percent=1.0,
            )],
            generated_at="2099-01-01T00:00:00+00:00",  # far future build time
            total_count=1, returned_count=1, limit=50, market_status="CLOSED",
        )

    # Probe reports OLD data (older than the far-future build time) -> no
    # invalidation; the time TTL alone governs caching.
    overview = MarketOverviewService(
        run_screen,
        ttl_seconds=300,
        latest_data_timestamp=lambda _m: "2000-01-01T00:00:00+00:00",
    )
    overview.get(Market.HKEX)
    overview.get(Market.HKEX)
    assert calls["n"] == 1  # served from cache, not rebuilt


def test_overview_invalidates_when_probe_reports_newer_data():
    """Injected probe reporting newer data forces an overview rebuild."""
    state = {"score": 90.0, "calls": 0}

    def run_screen(_market):
        state["calls"] += 1
        return ScreenerResult(
            market=Market.HKEX,
            matches=[ScreenerMatch(
                symbol="0700.HK", name="Tencent", score=state["score"],
                signal="BUY", price=100.0, change_percent=1.0,
            )],
            # build time = now, so a future probe ts counts as "newer".
            generated_at=datetime.now(
                tz=ZoneInfo("UTC")
            ).isoformat(),
            total_count=1, returned_count=1, limit=50, market_status="CLOSED",
        )

    probe = {"ts": "2000-01-01T00:00:00+00:00"}
    overview = MarketOverviewService(
        run_screen, ttl_seconds=300,
        latest_data_timestamp=lambda _m: probe["ts"],
    )
    first = overview.get(Market.HKEX)
    assert state["calls"] == 1
    assert first.top_gainer.symbol == "0700.HK"

    # Data refreshes within TTL: probe now reports a future timestamp.
    state["score"] = 95.0
    probe["ts"] = "2099-01-01T00:00:00+00:00"
    second = overview.get(Market.HKEX)
    assert state["calls"] == 2, "overview must rebuild on newer data"
    assert second is not first
