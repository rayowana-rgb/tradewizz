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
    import datetime as _dt

    fetcher = CountingFetcher()
    clock = FakeClock()
    # Pin "now" to the fixture's last bar (make_df ends 2024-01-10) so the
    # cache's settled data-date == today (the realistic invariant). This
    # isolates the test to TTL behavior, not the close-not-yet-settled retry.
    _now = _dt.datetime(2024, 1, 10, 18, 0, tzinfo=_dt.timezone.utc)
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=3600, clock=clock,
        now_provider=lambda _m: _now,
    )

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


def test_callable_ttl_is_evaluated_each_check(tmp_path):
    """A callable TTL lets the cache shorten while a market session is open."""
    import datetime as _dt

    fetcher = CountingFetcher()
    clock = FakeClock()
    state = {"ttl": 300}  # 5 min (e.g. "market open")
    # Pin "now" to the fixture's last bar so settled data-date == today; this
    # isolates the test to TTL behavior, not the close-not-yet-settled retry.
    _now = _dt.datetime(2024, 1, 10, 18, 0, tzinfo=_dt.timezone.utc)
    cache = OhlcvCache(
        fetcher, cache_dir=tmp_path, ttl_seconds=lambda: state["ttl"], clock=clock,
        now_provider=lambda _m: _now,
    )

    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1

    # Within the short (open) TTL -> hit.
    clock.advance(120)
    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1

    # Past the short TTL -> refetch (latest candle refreshes intraday).
    clock.advance(200)  # total 320s > 300s
    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 2

    # Now "market closed": long TTL keeps the (final) candle cached.
    state["ttl"] = 21600
    clock.advance(1000)
    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 2


def test_engine_dynamic_ttl_open_is_short_closed_is_long():
    from app import engine
    # The open TTL must be much shorter than the closed TTL so the latest
    # candle refreshes while a session is live.
    assert engine._CACHE_TTL_OPEN < engine._CACHE_TTL_CLOSED
    assert engine._CACHE_TTL_OPEN <= 600  # <= 10 min


def test_corrupt_duplicate_column_cache_is_rejected_and_refetched(tmp_path):
    # Regression: a poisoned cache file written from a multi-ticker yfinance
    # response carries DUPLICATE 'Close' columns. Reading it back must be
    # treated as a miss (not served), so the wrong price never leaks and the
    # cache self-heals on the next request. This is the durable defense for the
    # "screener prices drift back to wrong after a while" bug.
    fetcher = CountingFetcher()
    clock = FakeClock()
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600, clock=clock)

    df1 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1

    # Overwrite the on-disk CSV with a corrupted multi-ticker frame whose
    # header has LITERALLY duplicate 'Close' columns (exactly what a flattened
    # multi-ticker yfinance frame writes to disk in production).
    key = cache._key("BBCA.JK", "1y", "1d")
    csv_path, _ = cache._paths(key)
    csv_path.write_text(
        "Date,Open,High,Low,Close,Close,Volume\n"
        "2026-06-11,970,970,940,1010,5825,7660300\n"
        "2026-06-12,1010,1020,970,1010,5925,5680900\n"
    )

    # The corrupt file must NOT be served; the cache re-fetches clean data.
    df2 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 2  # corrupt entry rejected -> refetch
    assert list(df2.columns).count("Close") == 1
    assert df2["Close"].ndim == 1


# --------------------------------------------------------------------------- #
# Regression: provider returns an UNSETTLED (NaN-close) bar for today, so the
# cache must (a) not advertise today as its data date and (b) re-fetch (bounded)
# once the real close lands. This is the "screener shows yesterday's close under
# today's date" bug.
# --------------------------------------------------------------------------- #

from app.cache import _latest_index_ts, _settled_trading_date  # noqa: E402


def _df_with_trailing_nan_close():
    """Daily frame whose LAST row (today) has Close=NaN (unsettled bar)."""
    idx = pd.to_datetime(["2026-06-16", "2026-06-17", "2026-06-18"])
    return pd.DataFrame(
        {
            "Open": [100.0, 101.0, 102.0],
            "High": [101.0, 102.0, 103.0],
            "Low": [99.0, 100.0, 101.0],
            "Close": [100.0, 101.0, float("nan")],  # 18 Jun not settled
            "Volume": [1000.0, 1100.0, 0.0],
        },
        index=idx,
    )


def _df_all_settled():
    idx = pd.to_datetime(["2026-06-16", "2026-06-17", "2026-06-18"])
    return pd.DataFrame(
        {
            "Open": [100.0, 101.0, 102.0],
            "High": [101.0, 102.0, 103.0],
            "Low": [99.0, 100.0, 101.0],
            "Close": [100.0, 101.0, 105.0],  # 18 Jun now settled
            "Volume": [1000.0, 1100.0, 1200.0],
        },
        index=idx,
    )


def test_latest_index_ts_skips_trailing_nan_close():
    df = _df_with_trailing_nan_close()
    # Anchors to the last SETTLED close (17 Jun), not the NaN 18-Jun row.
    assert _latest_index_ts(df).startswith("2026-06-17")
    assert _settled_trading_date(df) == "2026-06-17"
    # Fully settled frame anchors to the newest row.
    assert _settled_trading_date(_df_all_settled()) == "2026-06-18"


class _StagedFetcher:
    """First call returns an unsettled-today frame, later calls the settled one."""

    def __init__(self):
        self.calls = 0

    def __call__(self, ticker, period, interval):
        self.calls += 1
        return _df_all_settled() if self.calls >= 2 else _df_with_trailing_nan_close()


def test_unsettled_today_bar_refetches_when_close_lands(tmp_path):
    import datetime as _dt

    fetcher = _StagedFetcher()
    clock = FakeClock()
    # Pin "now" to 18 Jun so trading_date_for() == 2026-06-18.
    now = _dt.datetime(2026, 6, 18, 18, 0, tzinfo=_dt.timezone.utc)
    cache = OhlcvCache(
        fetcher,
        cache_dir=tmp_path,
        ttl_seconds=3600,
        clock=clock,
        now_provider=lambda _m: now,
    )

    df1 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1
    # Fetched FOR 18 Jun, but only 17 Jun is settled -> the gap is recorded.
    key = cache._key("BBCA.JK", "1y", "1d")
    _, meta_path = cache._paths(key)
    import json as _json
    meta = _json.loads(meta_path.read_text())
    assert meta["trading_date"] == "2026-06-18"
    assert meta["settled_date"] == "2026-06-17"
    assert meta["latest_ts"].startswith("2026-06-17")
    assert df1["Close"].dropna().iloc[-1] == 101.0  # serves 17 Jun close

    # Within the lag-refetch interval: still served from cache (no fetch storm).
    clock.advance(60)
    cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 1

    # After the lag interval, re-fetch picks up the now-settled 18 Jun close.
    clock.advance(600)
    df2 = cache.get("BBCA.JK", "1y", "1d")
    assert fetcher.calls == 2
    assert df2["Close"].dropna().iloc[-1] == 105.0  # 18 Jun close now served
    meta2 = _json.loads(meta_path.read_text())
    assert meta2["trading_date"] == "2026-06-18"
    assert meta2["settled_date"] == "2026-06-18"  # gap closed
