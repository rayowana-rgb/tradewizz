"""Trading-day-aware OHLCV cache invalidation (req 3, 5).

Pins the core bug fix: after market close / on a new trading day / when the
provider has a newer candle, the cache must invalidate and refetch instead of
serving yesterday's close.
"""

from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

from app.cache import OhlcvCache

JKT = ZoneInfo("Asia/Jakarta")


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def make_df(last_date: str, close: float, n: int = 30) -> pd.DataFrame:
    idx = pd.date_range(end=last_date, periods=n, freq="D")
    closes = np.linspace(close - n, close, n)
    return pd.DataFrame(
        {
            "Open": closes, "High": closes + 1, "Low": closes - 1,
            "Close": closes, "Volume": np.full(n, 1000.0),
        },
        index=idx,
    )


class DayFetcher:
    """Returns a frame whose last close depends on a mutable 'day'."""

    def __init__(self):
        self.calls = 0
        self.day = "2026-06-08"
        self.close = 100.0

    def __call__(self, ticker, period, interval):
        self.calls += 1
        return make_df(self.day, self.close)


# --- next trading day invalidates ------------------------------------------

def test_new_trading_day_invalidates_cache(tmp_path):
    fetcher = DayFetcher()
    clock = FakeClock()
    now = {"dt": datetime(2026, 6, 8, 22, 0, tzinfo=JKT)}  # Day T, after close
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600, clock=clock,
        now_provider=lambda market: now["dt"],
    )

    # Day T: fetch close=100, cached.
    df = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1
    assert df["Close"].iloc[-1] == 100.0

    # Still Day T, within TTL -> hit, no refetch.
    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1

    # Day T+1 session: provider now has close=105 for the new day.
    now["dt"] = datetime(2026, 6, 9, 10, 0, tzinfo=JKT)
    fetcher.day = "2026-06-09"
    fetcher.close = 105.0
    df2 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 2  # trading day rolled -> refetch
    assert df2["Close"].iloc[-1] == 105.0


# --- market close (end of session) -> next day refresh ---------------------

def test_after_close_then_next_day_serves_fresh(tmp_path):
    fetcher = DayFetcher()
    clock = FakeClock()
    now = {"dt": datetime(2026, 6, 8, 16, 30, tzinfo=JKT)}  # just after close
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600, clock=clock,
        now_provider=lambda market: now["dt"],
    )
    cache.get("BBCA.JK")
    assert fetcher.calls == 1

    # Next morning before open: trading date stepped back? No -- 'current'
    # trading date pre-open is the PRIOR session (Day T), so still a hit.
    now["dt"] = datetime(2026, 6, 9, 7, 0, tzinfo=JKT)
    cache.get("BBCA.JK")
    assert fetcher.calls == 1

    # After the new session opens, trading date = Day T+1 -> refetch.
    now["dt"] = datetime(2026, 6, 9, 9, 30, tzinfo=JKT)
    fetcher.day = "2026-06-09"
    fetcher.close = 105.0
    df = cache.get("BBCA.JK")
    assert fetcher.calls == 2
    assert df["Close"].iloc[-1] == 105.0


# --- newer provider candle invalidates (req 5) -----------------------------

def test_newer_provider_candle_invalidates(tmp_path):
    fetcher = DayFetcher()
    clock = FakeClock()
    now = {"dt": datetime(2026, 6, 8, 11, 0, tzinfo=JKT)}  # same session
    provider_latest = {"ts": "2026-06-08T00:00:00"}
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600, clock=clock,
        now_provider=lambda market: now["dt"],
        latest_provider_timestamp=lambda t: provider_latest["ts"],
    )

    cache.get("BBCA.JK")
    assert fetcher.calls == 1

    # Same trading day, within TTL, but provider advertises a NEWER candle
    # (e.g. an intraday update). Must refetch even though TTL/date are fine.
    provider_latest["ts"] = "2026-06-08T07:00:00"
    fetcher.day = "2026-06-08"
    fetcher.close = 102.0
    cache.get("BBCA.JK")
    assert fetcher.calls == 2


def test_same_provider_candle_is_hit(tmp_path):
    fetcher = DayFetcher()
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600, clock=FakeClock(),
        now_provider=lambda market: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
        latest_provider_timestamp=lambda t: "2026-06-08T00:00:00",
    )
    cache.get("BBCA.JK")
    cache.get("BBCA.JK")
    assert fetcher.calls == 1  # provider ts unchanged -> hit


# --- TTL still applies within a day ----------------------------------------

def test_ttl_still_expires_within_same_day(tmp_path):
    fetcher = DayFetcher()
    clock = FakeClock()
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=300, clock=clock,
        now_provider=lambda market: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    assert fetcher.calls == 1
    clock.advance(301)
    cache.get("BBCA.JK")
    assert fetcher.calls == 2


# --- introspection / clear -------------------------------------------------

def test_entries_and_clear_by_symbol_and_market(tmp_path):
    fetcher = DayFetcher()
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=24 * 3600, clock=FakeClock(),
        now_provider=lambda market: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    cache.get("BBCA.JK")
    cache.get("0700.HK")
    entries = cache.entries()
    assert len(entries) == 2
    by_symbol = {e["symbol"]: e for e in entries}
    assert by_symbol["BBCA.JK"]["market"] == "IDX"
    assert by_symbol["0700.HK"]["market"] == "HKEX"
    assert by_symbol["BBCA.JK"]["latest_candle_ts"] is not None

    # Clear only HKEX.
    removed = cache.clear(market="HKEX")
    assert removed == 1
    assert {e["symbol"] for e in cache.entries()} == {"BBCA.JK"}

    # Clear by symbol.
    cache.get("0700.HK")
    removed = cache.clear(symbol="0700")
    assert removed == 1
    assert {e["symbol"] for e in cache.entries()} == {"BBCA.JK"}

    # Clear all.
    cache.get("0700.HK")
    removed = cache.clear()
    assert removed >= 1
    assert cache.entries() == []
