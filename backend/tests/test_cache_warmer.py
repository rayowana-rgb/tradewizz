"""Tests for the daily OHLCV cache warmer.

Deterministic and network-free: the symbol fetch, universe and per-market
"now" are all injected. We verify:
  * a market is warmed only once its regular session has closed for the day;
  * each market is warmed at most once per trading date (idempotent);
  * a new trading date re-triggers the warm;
  * markets close at DIFFERENT local times, so an open market is skipped while
    a closed one is warmed in the same pass;
  * throttling delay is honoured between fetches;
  * the warmer is opt-in / disabled under pytest.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from app.models import Market
from app.screener_cache.warmer import (
    DailyCacheWarmer,
    warmer_enabled,
)


def _now(market: Market, *, tz: str, y=2026, mo=6, d=17, h=18, mi=0):
    """Build a market-local datetime for the given clock time."""
    return datetime(y, mo, d, h, mi, tzinfo=ZoneInfo(tz))


class _Recorder:
    def __init__(self):
        self.calls = []

    def fetch(self, symbol, market):
        self.calls.append((market.value, symbol))


def _universe(mapping):
    return lambda mk: mapping.get(mk, [])


def test_only_warms_closed_markets():
    rec = _Recorder()
    # IDX closes 16:00 Asia/Jakarta; US closes 16:00 America/New_York.
    # At 18:00 Jakarta local, IDX is CLOSED but US is still mid-session.
    def now_provider(market):
        if market == Market.IDX:
            return _now(market, tz="Asia/Jakarta", h=18)
        # US: 18:00 Jakarta == ~07:00 ET (pre-market / not closed)
        return _now(market, tz="America/New_York", h=7)

    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.IDX: ["AAA", "BBB"], Market.US: ["MSFT"]}),
        markets=[Market.IDX, Market.US],
        fetch_delay_seconds=0.0,
        now_provider=now_provider,
    )
    warmed = w.tick()
    assert warmed == ["IDX"]
    assert rec.calls == [("IDX", "AAA"), ("IDX", "BBB")]


def test_idempotent_per_trading_date():
    rec = _Recorder()
    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.IDX: ["AAA", "BBB"]}),
        markets=[Market.IDX],
        fetch_delay_seconds=0.0,
        now_provider=lambda m: _now(m, tz="Asia/Jakarta", h=18),
    )
    assert w.tick() == ["IDX"]
    assert len(rec.calls) == 2
    # Second pass same trading date -> no re-warm.
    assert w.tick() == []
    assert len(rec.calls) == 2


def test_new_trading_date_rewarms():
    rec = _Recorder()
    day = {"d": 17}

    def now_provider(market):
        return _now(market, tz="Asia/Jakarta", d=day["d"], h=18)

    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.IDX: ["AAA"]}),
        markets=[Market.IDX],
        fetch_delay_seconds=0.0,
        now_provider=now_provider,
    )
    assert w.tick() == ["IDX"]
    assert len(rec.calls) == 1
    # Next trading day -> warm again.
    day["d"] = 18
    assert w.tick() == ["IDX"]
    assert len(rec.calls) == 2


def test_bad_symbol_never_stops_the_warm():
    seen = []

    def fetch(symbol, market):
        seen.append(symbol)
        if symbol == "BAD":
            raise RuntimeError("boom")

    w = DailyCacheWarmer(
        fetch_symbol=fetch,
        symbols_for=_universe({Market.IDX: ["AAA", "BAD", "CCC"]}),
        markets=[Market.IDX],
        fetch_delay_seconds=0.0,
        now_provider=lambda m: _now(m, tz="Asia/Jakarta", h=18),
    )
    assert w.tick() == ["IDX"]
    assert seen == ["AAA", "BAD", "CCC"]  # continued past the failure


def test_throttle_delay_is_applied(monkeypatch):
    rec = _Recorder()
    waits = []

    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.IDX: ["AAA", "BBB", "CCC"]}),
        markets=[Market.IDX],
        fetch_delay_seconds=0.4,
        now_provider=lambda m: _now(m, tz="Asia/Jakarta", h=18),
    )
    # Capture interruptible sleeps without actually sleeping.
    monkeypatch.setattr(w._stop, "wait", lambda t: waits.append(t) or False)
    w.tick()
    # One delay between each pair of fetches (n-1 delays for n symbols).
    assert waits == [0.4, 0.4]


def test_max_symbols_cap():
    rec = _Recorder()
    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.IDX: ["A", "B", "C", "D"]}),
        markets=[Market.IDX],
        fetch_delay_seconds=0.0,
        now_provider=lambda m: _now(m, tz="Asia/Jakarta", h=18),
    )
    w._max_symbols = 2
    w.tick()
    assert [s for _, s in rec.calls] == ["A", "B"]


def test_force_market_warms_even_when_open():
    rec = _Recorder()
    w = DailyCacheWarmer(
        fetch_symbol=rec.fetch,
        symbols_for=_universe({Market.US: ["MSFT"]}),
        markets=[Market.US],
        fetch_delay_seconds=0.0,
        # Pretend US is mid-session; force_market should warm anyway.
        now_provider=lambda m: _now(m, tz="America/New_York", h=11),
    )
    assert w.tick(force_market=Market.US) == ["US"]
    assert rec.calls == [("US", "MSFT")]


def test_warmer_disabled_under_pytest():
    # PYTEST_CURRENT_TEST is set while tests run -> always disabled.
    assert warmer_enabled() is False
