"""Tiny on-disk cache for OHLCV fetches.

Wraps an inner fetcher and memoizes its DataFrame result on disk, keyed by the
resolved Yahoo ticker + period + interval. Entries expire after a configurable
TTL (default 6 hours). The inner fetcher stays injectable so tests can run with
no network.

Storage: one CSV per cache key plus a small JSON sidecar holding the fetch
timestamp. CSV keeps it dependency-light (no parquet engine required).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable, Dict, Optional

import pandas as pd

logger = logging.getLogger("tradewiz.cache")

DEFAULT_TTL_SECONDS = 6 * 60 * 60  # 6 hours

# Inner fetcher: (ticker, period, interval) -> OHLCV DataFrame, or raises.
InnerFetcher = Callable[[str, str, str], pd.DataFrame]


def _default_cache_dir() -> Path:
    # Override with TRADEWIZ_CACHE_DIR; defaults to <backend>/.cache/ohlcv.
    env = os.environ.get("TRADEWIZ_CACHE_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent / ".cache" / "ohlcv"


def _ttl_from_env(default: int = DEFAULT_TTL_SECONDS) -> int:
    raw = os.environ.get("TRADEWIZ_CACHE_TTL_SECONDS")
    if raw is None:
        return default
    try:
        val = int(raw)
        return val if val > 0 else default
    except ValueError:
        return default


class OhlcvCache:
    """Disk-backed cache for OHLCV DataFrames."""

    def __init__(
        self,
        fetcher: InnerFetcher,
        cache_dir: Optional[Path | str] = None,
        ttl_seconds: Optional["int | Callable[[], int]"] = None,
        clock: Callable[[], float] = time.time,
    ):
        self._fetch = fetcher
        self._dir = Path(cache_dir) if cache_dir else _default_cache_dir()
        # TTL may be a fixed int or a callable evaluated per freshness check
        # (so it can shorten while a market session is open). Default from env.
        self._ttl = ttl_seconds if ttl_seconds is not None else _ttl_from_env()
        self._clock = clock
        self._dir.mkdir(parents=True, exist_ok=True)
        # Single-flight: one lock per cache key, guarded by a registry lock.
        # FastAPI runs sync endpoints in a threadpool, so real threading locks
        # are required (not asyncio locks).
        self._registry_lock = threading.Lock()
        self._key_locks: Dict[str, threading.Lock] = {}

    def _ttl_seconds(self) -> int:
        """Resolve the effective TTL (supports a callable for dynamic TTL)."""
        ttl = self._ttl
        return int(ttl() if callable(ttl) else ttl)

    def _lock_for(self, key: str) -> threading.Lock:
        with self._registry_lock:
            lock = self._key_locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._key_locks[key] = lock
            return lock

    # -- key/paths ---------------------------------------------------------

    @staticmethod
    def _key(ticker: str, period: str, interval: str) -> str:
        raw = f"{ticker.upper()}|{period}|{interval}"
        digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:16]
        return digest

    def _paths(self, key: str) -> tuple[Path, Path]:
        return self._dir / f"{key}.csv", self._dir / f"{key}.meta.json"

    # -- public ------------------------------------------------------------

    def get(
        self, ticker: str, period: str = "1y", interval: str = "1d"
    ) -> pd.DataFrame:
        """Return cached data if fresh, else fetch (single-flight), store, return.

        Concurrent cold requests for the same key share one underlying fetch:
        the first acquires the per-key lock and fetches; others block, then read
        the freshly written cache instead of duplicating the fetch.
        """
        key = self._key(ticker, period, interval)
        csv_path, meta_path = self._paths(key)

        # Fast path: fresh on disk, no lock needed.
        fresh = self._try_read_fresh(ticker, csv_path, meta_path)
        if fresh is not None:
            return fresh

        # Slow path: serialize per key so only one thread fetches.
        with self._lock_for(key):
            # Double-check: another thread may have populated it while we waited.
            fresh = self._try_read_fresh(ticker, csv_path, meta_path)
            if fresh is not None:
                logger.debug("single-flight hit %s (%s)", ticker, key)
                return fresh

            # We're the leader: fetch fresh (may raise -> caller handles).
            df = self._fetch(ticker, period, interval)
            try:
                self._write(csv_path, meta_path, df)
            except Exception as exc:  # noqa: BLE001 - cache write best-effort
                logger.warning("cache write failed for %s: %s", ticker, exc)
            return df

    def _try_read_fresh(
        self, ticker: str, csv_path: Path, meta_path: Path
    ) -> Optional[pd.DataFrame]:
        """Return cached data if present and fresh, else None."""
        if not self._is_fresh(meta_path):
            return None
        try:
            df = self._read(csv_path)
            logger.debug("cache hit %s", ticker)
            return df
        except Exception as exc:  # noqa: BLE001 - corrupt entry -> refetch
            logger.warning("cache read failed for %s: %s", ticker, exc)
            return None

    def clear(self) -> None:
        for p in self._dir.glob("*"):
            try:
                p.unlink()
            except OSError:
                pass

    # -- internals ---------------------------------------------------------

    def _is_fresh(self, meta_path: Path) -> bool:
        if not meta_path.exists():
            return False
        try:
            meta = json.loads(meta_path.read_text())
            fetched_at = float(meta.get("fetched_at", 0))
        except (ValueError, OSError):
            return False
        age = self._clock() - fetched_at
        return 0 <= age < self._ttl_seconds()

    def _read(self, csv_path: Path) -> pd.DataFrame:
        df = pd.read_csv(csv_path, index_col=0, parse_dates=True)
        if df.empty:
            raise ValueError("empty cached frame")
        return df

    def _write(self, csv_path: Path, meta_path: Path, df: pd.DataFrame) -> None:
        df.to_csv(csv_path)
        meta_path.write_text(json.dumps({"fetched_at": self._clock()}))


def make_cached_fetcher(
    inner: InnerFetcher,
    cache_dir: Optional[Path | str] = None,
    ttl_seconds: Optional["int | Callable[[], int]"] = None,
    clock: Callable[[], float] = time.time,
) -> Callable[[str, str, str], pd.DataFrame]:
    """Build a `(ticker, period, interval) -> df` fetcher backed by disk cache."""
    cache = OhlcvCache(inner, cache_dir, ttl_seconds, clock)
    return cache.get
