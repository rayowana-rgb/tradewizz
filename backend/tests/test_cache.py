"""On-disk OHLCV cache tests (no network).

Uses a counting fake fetcher + controllable clock + tmp dir, so we can prove
hit / miss / expiry deterministically.
"""

import numpy as np
import pandas as pd
import pytest

from app.cache import DEFAULT_TTL_SECONDS, OhlcvCache, make_cached_fetcher


class FakeClock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, secs):
        self.t += secs


def make_df(seed=0, n=10):
    rng = np.random.default_rng(seed)
    close = 100 + np.cumsum(rng.normal(0, 1, n))
    idx = pd.date_range("2024-01-01", periods=n, freq="D")
    return pd.DataFrame(
        {
            "Open": close,
            "High": close + 1,
            "Low": close - 1,
            "Close": close,
            "Volume": rng.integers(1000, 5000, n).astype("float64"),
        },
        index=idx,
    )


class CountingFetcher:
    """Returns a fresh DF each call and counts how many times it's invoked."""

    def __init__(self):
        self.calls = 0
        self.last_args = None

    def __call__(self, ticker, period, interval):
        self.calls += 1
        self.last_args = (ticker, period, interval)
        return make_df(seed=self.calls)


def test_miss_then_hit_avoids_second_fetch(tmp_path):
    fetcher = CountingFetcher()
    clock = FakeClock()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600, clock=clock)

    df1 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1  # miss -> fetched

    df2 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1  # hit -> no extra fetch
    # Values round-trip through CSV (index freq metadata is not preserved).
    assert list(df2.columns) == list(df1.columns)
    np.testing.assert_allclose(df2["Close"].values, df1["Close"].values)
    np.testing.assert_allclose(df2["Volume"].values, df1["Volume"].values)


def test_expiry_triggers_refetch(tmp_path):
    fetcher = CountingFetcher()
    clock = FakeClock()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600, clock=clock)

    cache.get("0700.HK", "1y", "1d")
    assert fetcher.calls == 1

    # Within TTL: still a hit.
    clock.advance(3599)
    cache.get("0700.HK", "1y", "1d")
    assert fetcher.calls == 1

    # Past TTL: expired -> refetch.
    clock.advance(2)
    cache.get("0700.HK", "1y", "1d")
    assert fetcher.calls == 2


def test_distinct_keys_per_ticker_period_interval(tmp_path):
    fetcher = CountingFetcher()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600,
                       clock=FakeClock())

    cache.get("AAA.KS", "1y", "1d")
    cache.get("AAA.KS", "6mo", "1d")   # different period
    cache.get("AAA.KS", "1y", "1wk")   # different interval
    cache.get("BBB.KS", "1y", "1d")    # different ticker
    assert fetcher.calls == 4

    # Repeats of each are hits.
    cache.get("AAA.KS", "1y", "1d")
    cache.get("BBB.KS", "1y", "1d")
    assert fetcher.calls == 4


def test_default_ttl_is_six_hours():
    assert DEFAULT_TTL_SECONDS == 6 * 60 * 60


def test_corrupt_cache_entry_refetches(tmp_path):
    fetcher = CountingFetcher()
    clock = FakeClock()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600, clock=clock)

    cache.get("ZZZ.KQ", "1y", "1d")
    assert fetcher.calls == 1

    # Corrupt the CSV but keep meta "fresh" -> read fails -> refetch.
    key = OhlcvCache._key("ZZZ.KQ", "1y", "1d")
    (tmp_path / f"{key}.csv").write_text("not,a,valid\x00csv")
    cache.get("ZZZ.KQ", "1y", "1d")
    assert fetcher.calls == 2


def test_fetch_error_propagates_and_is_not_cached(tmp_path):
    calls = {"n": 0}

    def boom(ticker, period, interval):
        calls["n"] += 1
        raise ConnectionError("offline")

    cache = OhlcvCache(boom, cache_dir=tmp_path, ttl_seconds=3600,
                       clock=FakeClock())

    with pytest.raises(ConnectionError):
        cache.get("X.JK", "1y", "1d")
    with pytest.raises(ConnectionError):
        cache.get("X.JK", "1y", "1d")
    assert calls["n"] == 2  # nothing cached on failure


def test_make_cached_fetcher_is_callable(tmp_path):
    fetcher = CountingFetcher()
    cached = make_cached_fetcher(fetcher, cache_dir=tmp_path, ttl_seconds=3600,
                                 clock=FakeClock())
    cached("Q.JK", "1y", "1d")
    cached("Q.JK", "1y", "1d")
    assert fetcher.calls == 1  # second call served from cache


def test_ttl_from_env(tmp_path, monkeypatch):
    monkeypatch.setenv("TRADEWIZ_CACHE_TTL_SECONDS", "120")
    fetcher = CountingFetcher()
    clock = FakeClock()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, clock=clock)  # TTL from env
    cache.get("E.HK", "1y", "1d")
    clock.advance(121)
    cache.get("E.HK", "1y", "1d")
    assert fetcher.calls == 2
