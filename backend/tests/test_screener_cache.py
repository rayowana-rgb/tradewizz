"""Tests for market-close screener result caching.

Covers the required scenarios:
  * market OPEN returns a cached snapshot (and does NOT run heavy screening when
    a snapshot exists)
  * market CLOSED with no snapshot runs and saves once
  * market CLOSED with an existing snapshot returns the cached result (no rerun)
  * the next market date triggers a fresh run/save
  * cache is separated by market and by category/params
  * force_refresh is allowed only when CLOSED; OPEN -> latest cache + warning
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from app.models import Market, ScreenerMatch, ScreenerResult
from app.screener_cache import InMemoryScreenerSnapshotStore
from app.screener_cache.service import (
    FORCE_REFRESH_DENIED,
    NEXT_REFRESH_RULE,
    REASON_OPEN,
    ScreenerCacheService,
    make_cache_key,
)

HK = ZoneInfo("Asia/Hong_Kong")

# A weekday during HKEX hours (09:00-16:00 local) -> OPEN.
OPEN_TIME = datetime(2026, 6, 8, 11, 0, tzinfo=HK)  # Monday 11:00 HKT
# Same weekday after the close -> CLOSED.
CLOSED_TIME = datetime(2026, 6, 8, 18, 0, tzinfo=HK)  # Monday 18:00 HKT
NEXT_DAY_CLOSED = datetime(2026, 6, 9, 18, 0, tzinfo=HK)  # Tuesday 18:00 HKT


def _result(market=Market.HKEX, n=3, score0=90.0) -> ScreenerResult:
    matches = [
        ScreenerMatch(
            symbol=f"SYM{i}",
            name=f"Name {i}",
            score=score0 - i,
            signal="BUY",
            price=100.0 + i,
            change_percent=1.0 + i,
        )
        for i in range(n)
    ]
    return ScreenerResult(
        market=market,
        matches=matches,
        generated_at="2026-06-08T00:00:00+00:00",
        total_count=n,
        returned_count=n,
        limit=50,
    )


class _Counter:
    """A run_screen callable that counts invocations and tags each run."""

    def __init__(self, market=Market.HKEX):
        self.calls = 0
        self._market = market

    def __call__(self) -> ScreenerResult:
        self.calls += 1
        # Encode the call index in score so reruns are distinguishable.
        return _result(market=self._market, score0=90.0 + self.calls)


def _service(store, run, now: datetime, **kw) -> ScreenerCacheService:
    return ScreenerCacheService(
        store, run, now_provider=lambda _m: now, **kw
    )


KEY = make_cache_key(category="", limit=50, min_score=0.0, min_value_traded=0.0)


# --------------------------------------------------------------------------- #
# CLOSED: run + save once, then reuse                                         #
# --------------------------------------------------------------------------- #
def test_closed_no_snapshot_runs_and_saves():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()
    svc = _service(store, run, CLOSED_TIME)

    res = svc.get(Market.HKEX, KEY)

    assert run.calls == 1
    assert store.save_count == 1
    assert res.cached is False
    assert res.market_status == "CLOSED"
    assert res.market_date == "2026-06-08"
    assert res.next_refresh_rule == NEXT_REFRESH_RULE
    assert len(res.matches) == 3


def test_closed_existing_snapshot_returns_cached_no_rerun():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()
    svc = _service(store, run, CLOSED_TIME)

    first = svc.get(Market.HKEX, KEY)
    assert run.calls == 1

    # Same day, second open of the app -> reuse, do not rerun.
    second = svc.get(Market.HKEX, KEY)
    assert run.calls == 1  # NOT re-run
    assert store.save_count == 1
    assert second.cached is True
    assert second.market_status == "CLOSED"
    # Same payload as the saved snapshot.
    assert [m.symbol for m in second.matches] == [
        m.symbol for m in first.matches
    ]


# --------------------------------------------------------------------------- #
# OPEN: never run heavy screening when a snapshot exists                       #
# --------------------------------------------------------------------------- #
def test_open_returns_cached_snapshot_and_does_not_screen():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()

    # Produce a market-close snapshot first.
    closed = _service(store, run, CLOSED_TIME)
    closed.get(Market.HKEX, KEY)
    assert run.calls == 1

    # Now the market opens; opening the app must reuse the snapshot.
    opened = _service(store, run, OPEN_TIME)
    res = opened.get(Market.HKEX, KEY)

    assert run.calls == 1  # heavy screening did NOT run while open
    assert res.cached is True
    assert res.market_status == "OPEN"
    assert res.warning == REASON_OPEN
    assert res.next_refresh_rule == NEXT_REFRESH_RULE


def test_open_strict_no_snapshot_does_not_screen():
    """With cold_open_live disabled, an open market never screens."""
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()
    svc = _service(store, run, OPEN_TIME, cold_open_live=False)

    res = svc.get(Market.HKEX, KEY)

    assert run.calls == 0  # strictly no screening while open
    assert res.matches == []
    assert res.cached is True
    assert res.market_status == "OPEN"
    assert res.next_refresh_rule == NEXT_REFRESH_RULE


# --------------------------------------------------------------------------- #
# Next market date -> fresh run/save                                           #
# --------------------------------------------------------------------------- #
def test_next_market_date_triggers_fresh_run():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()

    _service(store, run, CLOSED_TIME).get(Market.HKEX, KEY)
    assert run.calls == 1

    # Next trading day, after close -> today's snapshot doesn't exist yet.
    res = _service(store, run, NEXT_DAY_CLOSED).get(Market.HKEX, KEY)
    assert run.calls == 2  # re-ran for the new market date
    assert store.save_count == 2
    assert res.cached is False
    assert res.market_date == "2026-06-09"


# --------------------------------------------------------------------------- #
# Cache separation                                                             #
# --------------------------------------------------------------------------- #
def test_cache_separated_by_market():
    store = InMemoryScreenerSnapshotStore()
    run_hk = _Counter(market=Market.HKEX)
    run_idx = _Counter(market=Market.IDX)

    _service(store, run_hk, CLOSED_TIME).get(Market.HKEX, KEY)
    _service(store, run_idx, CLOSED_TIME).get(Market.IDX, KEY)

    assert run_hk.calls == 1
    assert run_idx.calls == 1
    assert store.has_for_date("HKEX", "2026-06-08")
    assert store.has_for_date("IDX", "2026-06-08")


def test_cache_separated_by_category_and_params():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()
    svc = _service(store, run, CLOSED_TIME)

    key_all = make_cache_key(
        category="", limit=50, min_score=0.0, min_value_traded=0.0
    )
    key_bullish = make_cache_key(
        category="bullish", limit=50, min_score=0.0, min_value_traded=0.0
    )
    key_limit2 = make_cache_key(
        category="", limit=2, min_score=0.0, min_value_traded=0.0
    )

    assert key_all != key_bullish != key_limit2
    svc.get(Market.HKEX, key_all)
    svc.get(Market.HKEX, key_bullish)
    svc.get(Market.HKEX, key_limit2)

    # Three distinct keys -> three separate heavy runs + saves.
    assert run.calls == 3
    assert store.save_count == 3


# --------------------------------------------------------------------------- #
# force_refresh safety                                                         #
# --------------------------------------------------------------------------- #
def test_force_refresh_allowed_when_closed():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()
    svc = _service(store, run, CLOSED_TIME)

    svc.get(Market.HKEX, KEY)  # initial snapshot
    assert run.calls == 1

    res = svc.get(Market.HKEX, KEY, force_refresh=True)
    assert run.calls == 2  # forced a fresh run
    assert res.cached is False
    assert res.warning is None


def test_force_refresh_denied_when_open():
    store = InMemoryScreenerSnapshotStore()
    run = _Counter()

    # Seed a snapshot while closed.
    _service(store, run, CLOSED_TIME).get(Market.HKEX, KEY)
    assert run.calls == 1

    # Force refresh while OPEN -> denied: return latest cache + warning.
    res = _service(store, run, OPEN_TIME).get(
        Market.HKEX, KEY, force_refresh=True
    )
    assert run.calls == 1  # did NOT screen
    assert res.cached is True
    assert res.warning == FORCE_REFRESH_DENIED
