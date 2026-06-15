"""Regression tests: CLOSED screener snapshots must re-validate against the
underlying OHLCV/analyze data instead of serving a frozen snapshot.

Bug: when the market was CLOSED and today's snapshot already existed, the
screener cache returned it blindly. Meanwhile ``/analyze`` reads the live OHLCV
cache, which can refresh on the same trading date (e.g. the latest close moves
or a correction prints). Result: the Detail page showed fresh prices while the
Screener list and the Dashboard top-movers (both backed by ``/screen``) stayed
frozen until a backend restart.

Fix: before reusing a CLOSED snapshot, compare its ``generated_at`` against a
cache-only "latest data timestamp" probe for the market. If the underlying data
is newer, rebuild + re-save the snapshot. These tests drive that probe directly
so they are deterministic and never touch the network.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from app.models import Market, ScreenerMatch, ScreenerResult
from app.screener_cache import InMemoryScreenerSnapshotStore
from app.screener_cache.service import (
    ScreenerCacheService,
    make_cache_key,
)

HK = ZoneInfo("Asia/Hong_Kong")
# Monday, after the HKEX close -> CLOSED, same trading date throughout.
CLOSED_TIME = datetime(2026, 6, 8, 18, 0, tzinfo=HK)

KEY = make_cache_key(
    category="", limit=50, min_score=0.0, min_value_traded=0.0
)


def _iso(offset_seconds: float) -> str:
    """An ISO-8601 UTC timestamp ``offset_seconds`` from now.

    Snapshots are saved with ``generated_at = now()`` (real wall clock), so the
    probe must return real-clock-relative timestamps to model "newer" vs
    "older" data deterministically.
    """
    return (
        datetime.now(timezone.utc) + timedelta(seconds=offset_seconds)
    ).isoformat()


# Snapshot freshness is decided by TRADING DATE, not raw instant (a snapshot
# stays valid for its whole trading day; only a candle from a strictly later
# trading day invalidates it). These constants return candle timestamps
# anchored to a trading day so the date comparison is what is exercised.
#
# CLOSED_TIME is 2026-06-08 (HKEX) -> the snapshot's market_date is
# "2026-06-08". A SAME-day candle must reuse; a NEXT-day candle must rebuild.
# (HKEX trading-date mapping rolls the calendar boundary; these instants are
# chosen so trading_date_str(HKEX, ts) yields exactly the dates noted.)
_SAME_DAY_CANDLE = "2026-06-08T12:00:00+00:00"   # trading date 2026-06-08 -> reuse
_NEXT_DAY_CANDLE = "2026-06-09T12:00:00+00:00"   # trading date 2026-06-09 -> rebuild


def _result(price: float, *, generated_at: str) -> ScreenerResult:
    """A one-symbol screener result at a given close price."""
    return ScreenerResult(
        market=Market.HKEX,
        matches=[
            ScreenerMatch(
                symbol="0700.HK",
                name="Tencent",
                score=90.0,
                signal="BUY",
                price=price,
                change_percent=1.0,
            )
        ],
        generated_at=generated_at,
        total_count=1,
        returned_count=1,
        limit=50,
    )


class _Engine:
    """Stand-in for the heavy engine: returns whatever close is set on it.

    ``price`` mirrors the OHLCV/analyze data: bumping it models the live cache
    refreshing on the same trading date (the value the Detail page would show).
    """

    def __init__(self) -> None:
        self.price = 100.0
        self.calls = 0

    def run_screen(self) -> ScreenerResult:
        self.calls += 1
        return _result(
            self.price, generated_at=f"2026-06-08T0{self.calls}:00:00+00:00"
        )


def _service(store, engine, *, data_ts):
    """Build a service with an injected, cache-only data-timestamp probe."""
    return ScreenerCacheService(
        store,
        engine.run_screen,
        now_provider=lambda _m: CLOSED_TIME,
        latest_data_timestamp=data_ts,
    )


def test_closed_snapshot_rebuilds_when_ohlcv_data_refreshed():
    """screen builds at 100; OHLCV refreshes to 110 same date; screen rebuilds.

    Mirrors: Detail page (/analyze) shows 110, so the Screener list must too.
    """
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()

    # Snapshot saved for trading date 2026-06-08; probe reports a candle for the
    # SAME trading day, so the first build is not re-run.
    data = {"ts": _SAME_DAY_CANDLE}
    svc = _service(store, engine, data_ts=lambda _m: data["ts"])

    first = svc.get(Market.HKEX, KEY)
    assert first.matches[0].price == 100.0
    assert first.cached is False
    assert engine.calls == 1

    # --- A NEWER trading-day candle appears (next session). ---
    engine.price = 110.0
    # The cache-only probe now reports a candle for a STRICTLY LATER trading day
    # than the snapshot's market_date.
    data["ts"] = _NEXT_DAY_CANDLE

    second = svc.get(Market.HKEX, KEY)

    # Must REBUILD rather than serve the frozen 100.
    assert second.matches[0].price == 110.0, "stale snapshot served"
    assert second.cached is False
    assert engine.calls == 2
    assert store.save_count == 2


def test_dashboard_path_via_screen_also_gets_refreshed_value():
    """The dashboard top-movers use the same /screen path -> same refreshed 110."""
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()
    data = {"ts": _SAME_DAY_CANDLE}
    svc = _service(store, engine, data_ts=lambda _m: data["ts"])

    svc.get(Market.HKEX, KEY)  # build at 100
    engine.price = 110.0
    data["ts"] = _NEXT_DAY_CANDLE

    # Dashboard calls the very same cache_key/path as the screener list.
    dashboard = svc.get(Market.HKEX, KEY)
    movers = sorted(
        dashboard.matches, key=lambda m: m.change_percent, reverse=True
    )
    assert movers[0].price == 110.0


def test_closed_snapshot_reused_when_data_not_newer():
    """No newer data -> keep existing snapshot (no rebuild), behavior unchanged."""
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()
    # Probe reports a candle for the SAME trading day as the snapshot.
    svc = _service(store, engine, data_ts=lambda _m: _SAME_DAY_CANDLE)

    first = svc.get(Market.HKEX, KEY)
    assert engine.calls == 1
    engine.price = 999.0  # would change if it rebuilt

    second = svc.get(Market.HKEX, KEY)
    assert engine.calls == 1, "should NOT rebuild when data is not newer"
    assert second.cached is True
    assert second.matches[0].price == first.matches[0].price == 100.0


def test_indeterminate_probe_keeps_existing_snapshot():
    """Probe returns None (nothing cached) -> reuse snapshot, no rebuild."""
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()
    svc = _service(store, engine, data_ts=lambda _m: None)

    svc.get(Market.HKEX, KEY)
    assert engine.calls == 1
    engine.price = 999.0

    second = svc.get(Market.HKEX, KEY)
    assert engine.calls == 1
    assert second.cached is True
    assert second.matches[0].price == 100.0


def test_real_registry_probe_keeps_snapshot_on_same_day_cache_rewrite(tmp_path):
    """End-to-end with the default cache-registry probe + a real OHLCV cache.

    Regression for "screener results keep changing while the market is closed":
    a CLOSED-session snapshot must STAY frozen when the OHLCV cache is merely
    re-written on the SAME trading date (cache write-time / fetched_at moves but
    the candle date does not). Previously the probe also considered fetched_at,
    so any cache rewrite -- e.g. opening a stock detail page -- rebuilt the
    snapshot, and each rebuild re-screened the universe with whatever yfinance
    availability existed at that instant, shifting the result set/ranking.
    """
    import time

    import numpy as np
    import pandas as pd

    from app.cache import OhlcvCache
    from app.engine import AnalysisEngine

    def mkdf(close: float, n: int = 120) -> pd.DataFrame:
        # Candle date is FIXED (same trading day); only the value/write-time
        # changes below.
        idx = pd.date_range(end="2026-06-08", periods=n, freq="D")
        c = np.linspace(close - 5, close, n)
        return pd.DataFrame(
            {
                "Open": c, "High": c + 1, "Low": c - 1, "Close": c,
                "Volume": np.full(n, 5e6),
            },
            index=idx,
        )

    state = {"close": 100.0}
    cache = OhlcvCache(
        lambda t, p, i: mkdf(state["close"]),
        cache_dir=tmp_path,
        ttl_seconds=300,
        now_provider=lambda _m: CLOSED_TIME,
    )
    engine = AnalysisEngine(fetcher=cache.get)
    store = InMemoryScreenerSnapshotStore()
    svc = ScreenerCacheService(
        store,
        lambda: engine.screen(
            Market.HKEX, symbols=["0700.HK"], limit=50
        ),
        now_provider=lambda _m: CLOSED_TIME,
        # default latest_data_timestamp = live cache-registry probe
    )

    # Prime the OHLCV cache (so a candle exists) and build the snapshot @100.
    engine.analyze("0700.HK", Market.HKEX)
    first = svc.get(Market.HKEX, KEY)
    assert first.cached is False
    p0 = first.matches[0].price

    # Same trading date: cache is cleared + rewritten (fetched_at advances),
    # but the candle DATE is unchanged.
    time.sleep(1.1)
    state["close"] = 110.0
    cache.clear(symbol="0700")
    engine.analyze("0700.HK", Market.HKEX)

    # The CLOSED snapshot must be served unchanged (frozen), not rebuilt.
    second = svc.get(Market.HKEX, KEY)
    assert second.cached is True
    assert second.matches[0].price == p0


def test_force_refresh_while_closed_rebuilds_regardless():
    """force_refresh=True while CLOSED always rebuilds (unchanged behavior)."""
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()
    # Even with a SAME-day (not-newer) candle, force_refresh must rebuild.
    svc = _service(store, engine, data_ts=lambda _m: _SAME_DAY_CANDLE)

    svc.get(Market.HKEX, KEY)
    assert engine.calls == 1
    engine.price = 110.0

    forced = svc.get(Market.HKEX, KEY, force_refresh=True)
    assert engine.calls == 2
    assert forced.cached is False
    assert forced.matches[0].price == 110.0


def test_closed_screen_is_stable_across_requests_despite_engine_variance():
    """User-facing regression: while CLOSED, /screen must NOT keep changing.

    The engine can return a different result set on each run (yfinance
    availability varies -> different symbols succeed/skip -> different
    total_count + ranking). The market-close cache must freeze the FIRST
    snapshot and serve it identically on every subsequent request, as long as
    no newer trading-day candle appears. Previously the default probe also
    reacted to cache WRITE-TIME, so any cache rewrite rebuilt the snapshot and
    the list visibly changed between runs even though the market was equally
    closed.
    """
    store = InMemoryScreenerSnapshotStore()
    engine = _Engine()
    # Probe reports a SAME-day candle -> never a newer trading day -> no rebuild.
    svc = _service(store, engine, data_ts=lambda _m: _SAME_DAY_CANDLE)

    first = svc.get(Market.HKEX, KEY)
    assert first.cached is False
    assert engine.calls == 1

    # The engine would now produce a DIFFERENT result if re-run...
    engine.price = 137.0
    # ...but repeated CLOSED requests must return the identical frozen snapshot.
    for _ in range(5):
        again = svc.get(Market.HKEX, KEY)
        assert again.cached is True
        assert again.total_count == first.total_count
        assert [m.symbol for m in again.matches] == [
            m.symbol for m in first.matches
        ]
        assert again.matches[0].price == first.matches[0].price
    assert engine.calls == 1  # never re-screened
