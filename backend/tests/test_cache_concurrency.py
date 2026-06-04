"""Single-flight concurrency guard tests for OhlcvCache (no network).

Uses real threads with a fetcher that blocks, so multiple threads are in the
cold path at once. Proves: same-key concurrent calls fetch once, different keys
fetch independently, and a failed fetch does not poison the cache.
"""

import threading
import time

import numpy as np
import pandas as pd

from app.cache import OhlcvCache


def make_df(n=10):
    close = 100 + np.arange(n, dtype="float64")
    idx = pd.date_range("2024-01-01", periods=n, freq="D")
    return pd.DataFrame(
        {
            "Open": close,
            "High": close + 1,
            "Low": close - 1,
            "Close": close,
            "Volume": np.full(n, 1000.0),
        },
        index=idx,
    )


class BlockingFetcher:
    """Counts calls; each call blocks briefly so threads overlap in the fetch."""

    def __init__(self, delay=0.2, error=False):
        self.delay = delay
        self.error = error
        self.calls = 0
        self._lock = threading.Lock()
        self.seen_keys = []

    def __call__(self, ticker, period, interval):
        with self._lock:
            self.calls += 1
            self.seen_keys.append((ticker, period, interval))
        time.sleep(self.delay)  # hold the cold path so others pile up
        if self.error:
            raise ConnectionError("offline")
        return make_df()


def _run_concurrent(fn, n):
    """Run fn() in n threads, collecting (result, exception) tuples."""
    results = [None] * n
    errors = [None] * n
    barrier = threading.Barrier(n)

    def worker(i):
        barrier.wait()  # release all threads at once
        try:
            results[i] = fn()
        except Exception as exc:  # noqa: BLE001
            errors[i] = exc

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results, errors


def test_concurrent_same_key_fetches_once(tmp_path):
    fetcher = BlockingFetcher(delay=0.2)
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600)

    results, errors = _run_concurrent(
        lambda: cache.get("BBCA.JK", "1y", "1d"), n=8
    )

    assert all(e is None for e in errors)
    assert all(r is not None for r in results)
    assert fetcher.calls == 1  # single-flight: only one underlying fetch


def test_concurrent_different_keys_fetch_independently(tmp_path):
    fetcher = BlockingFetcher(delay=0.1)
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600)

    tickers = ["AAA.JK", "BBB.JK", "CCC.JK", "DDD.JK"]
    barrier = threading.Barrier(len(tickers))

    def worker(ticker):
        barrier.wait()
        cache.get(ticker, "1y", "1d")

    threads = [threading.Thread(target=worker, args=(t,)) for t in tickers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert fetcher.calls == len(tickers)  # each distinct key fetched once


def test_same_ticker_different_period_interval_are_distinct(tmp_path):
    fetcher = BlockingFetcher(delay=0.1)
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600)

    calls = [
        ("AAA.JK", "1y", "1d"),
        ("AAA.JK", "6mo", "1d"),
        ("AAA.JK", "1y", "1wk"),
    ]
    barrier = threading.Barrier(len(calls))

    def worker(args):
        barrier.wait()
        cache.get(*args)

    threads = [threading.Thread(target=worker, args=(c,)) for c in calls]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert fetcher.calls == 3  # different keys -> independent fetches


def test_failed_fetch_does_not_poison_cache(tmp_path):
    fetcher = BlockingFetcher(delay=0.1, error=True)
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600)

    # Concurrent failing calls: each surfaces the error, nothing cached.
    results, errors = _run_concurrent(
        lambda: cache.get("ERR.JK", "1y", "1d"), n=5
    )
    assert all(isinstance(e, ConnectionError) for e in errors)
    assert all(r is None for r in results)
    first_calls = fetcher.calls
    assert first_calls >= 1

    # Now make the fetcher succeed: a subsequent call must fetch (not serve a
    # poisoned/empty entry) and return data.
    fetcher.error = False
    df = cache.get("ERR.JK", "1y", "1d")
    assert df is not None and not df.empty
    assert fetcher.calls == first_calls + 1


def test_after_single_flight_subsequent_calls_are_hits(tmp_path):
    fetcher = BlockingFetcher(delay=0.05)
    cache = OhlcvCache(fetcher, cache_dir=tmp_path, ttl_seconds=3600)

    _run_concurrent(lambda: cache.get("Z.JK", "1y", "1d"), n=4)
    assert fetcher.calls == 1

    # Later sequential calls hit the warm cache.
    cache.get("Z.JK", "1y", "1d")
    cache.get("Z.JK", "1y", "1d")
    assert fetcher.calls == 1
