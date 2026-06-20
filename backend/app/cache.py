"""Tiny on-disk cache for OHLCV fetches.

Wraps an inner fetcher and memoizes its DataFrame result on disk, keyed by the
resolved Yahoo ticker + period + interval. Entries expire after a configurable
TTL (default 6 hours). The inner fetcher stays injectable so tests can run with
no network.

Trading-day awareness (fixes stale prices after market close): every entry is
tagged with the *trading date* it was fetched for (the market-local current /
most-recent session date) and the *latest candle timestamp* inside the frame.
A cached entry is only served when ALL of:
  * it is within the age-based TTL, AND
  * its trading date matches the current trading date for the symbol's market
    (so a new session day always invalidates yesterday's entry), AND
  * the latest candle in the cached frame is not older than what the provider
    reports as available (optional, when a ``latest_provider_timestamp`` hook
    is wired) -- a newer provider candle invalidates + refetches.

Storage: one CSV per cache key plus a small JSON sidecar holding the fetch
timestamp, trading date and latest candle timestamp. CSV keeps it
dependency-light (no parquet engine required).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import threading
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional

import pandas as pd

from .market_session import market_for_ticker, trading_date_str

logger = logging.getLogger("tradewiz.cache")

DEFAULT_TTL_SECONDS = 6 * 60 * 60  # 6 hours

# Minimum age before a cache whose data date lags the current session's date is
# re-fetched. Bounds how often we re-hit the provider while it is still serving
# an unsettled (NaN-close) bar for today: at most once per this interval per
# symbol, instead of on every request. Settled data arrives within minutes of
# the close in practice, so 10 minutes keeps prices current without hammering
# the provider.
_LAG_REFETCH_MIN_S = int(os.environ.get("TRADEWIZ_CACHE_LAG_REFETCH_S", "600"))

# Inner fetcher: (ticker, period, interval) -> OHLCV DataFrame, or raises.
InnerFetcher = Callable[[str, str, str], pd.DataFrame]
# Optional provider-latest-timestamp probe: ticker -> ISO timestamp string of
# the newest candle the provider currently has, or None if unknown/unavailable.
LatestProviderTimestamp = Callable[[str], Optional[str]]


# Registry of all live caches so the /v1/debug/cache endpoints can enumerate
# and clear entries across every cache instance in the process.
_CACHE_REGISTRY: "List[OhlcvCache]" = []
_REGISTRY_GUARD = threading.Lock()


def register_cache(cache: "OhlcvCache") -> None:
    with _REGISTRY_GUARD:
        if cache not in _CACHE_REGISTRY:
            _CACHE_REGISTRY.append(cache)


def all_caches() -> "List[OhlcvCache]":
    with _REGISTRY_GUARD:
        return list(_CACHE_REGISTRY)


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


def _latest_index_ts(df: pd.DataFrame) -> Optional[str]:
    """ISO timestamp of the newest *settled* row in an OHLCV frame, or None.

    Critical correctness fix (the "prices one day stale" bug): yfinance often
    returns a row for the in-progress / just-closed session whose ``Close`` is
    still ``NaN`` (the bar hasn't settled at fetch time). The engine reads the
    price from ``Close.dropna().iloc[-1]`` -- i.e. the last row WITH a real
    close -- so it serves the prior session's price. If ``latest_ts`` instead
    pointed at that trailing NaN row, the cache would record a newer candle
    timestamp than the price it can actually serve. Every downstream freshness
    probe (cache ``newer_provider_candle`` check, screener-snapshot
    revalidation) would then believe the cache is up to date and never
    re-fetch, freezing the stale price even after the real close lands.

    So anchor ``latest_ts`` to the newest row that carries a usable ``Close``,
    matching exactly what the engine prices off of. When a later fetch brings a
    settled close for the newer session, ``provider_ts`` advances past this
    value and the cache correctly invalidates.
    """
    try:
        if df is None or df.empty:
            return None
        if "Close" in df.columns:
            settled = df["Close"].dropna()
            if not settled.empty:
                return pd.Timestamp(settled.index[-1]).isoformat()
        idx = df.index[-1]
        return pd.Timestamp(idx).isoformat()
    except Exception:  # noqa: BLE001
        return None


def _settled_trading_date(df: pd.DataFrame) -> Optional[str]:
    """YYYY-MM-DD of the newest row with a settled ``Close``, or None.

    Mirrors :func:`_latest_index_ts` but returns just the calendar date, used to
    anchor the cache's ``trading_date`` to the data it can actually serve rather
    than the wall clock (see :meth:`OhlcvCache._write`).
    """
    try:
        if df is None or df.empty or "Close" not in df.columns:
            return None
        settled = df["Close"].dropna()
        if settled.empty:
            return None
        return pd.Timestamp(settled.index[-1]).date().isoformat()
    except Exception:  # noqa: BLE001
        return None


class OhlcvCache:
    """Disk-backed, trading-day-aware cache for OHLCV DataFrames."""

    def __init__(
        self,
        fetcher: InnerFetcher,
        cache_dir: Optional[Path | str] = None,
        ttl_seconds: Optional["int | Callable[[], int]"] = None,
        clock: Callable[[], float] = time.time,
        latest_provider_timestamp: Optional[LatestProviderTimestamp] = None,
        now_provider: Optional[Callable[[str], object]] = None,
    ):
        self._fetch = fetcher
        self._dir = Path(cache_dir) if cache_dir else _default_cache_dir()
        # TTL may be a fixed int or a callable evaluated per freshness check
        # (so it can shorten while a market session is open). Default from env.
        self._ttl = ttl_seconds if ttl_seconds is not None else _ttl_from_env()
        self._clock = clock
        # Optional hook: ticker -> ISO timestamp of newest provider candle.
        self._latest_provider = latest_provider_timestamp
        # Optional injectable "now" for trading-date computation (tests).
        # Signature: (market_code:str) -> datetime.
        self._now_provider = now_provider
        self._dir.mkdir(parents=True, exist_ok=True)
        # Single-flight: one lock per cache key, guarded by a registry lock.
        # FastAPI runs sync endpoints in a threadpool, so real threading locks
        # are required (not asyncio locks).
        self._registry_lock = threading.Lock()
        self._key_locks: Dict[str, threading.Lock] = {}
        register_cache(self)

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

    # -- trading-day helpers ----------------------------------------------

    def _trading_date_for(self, ticker: str) -> str:
        market = market_for_ticker(ticker)
        if self._now_provider is not None:
            try:
                now = self._now_provider(market)
                return trading_date_str(market, now)
            except Exception:  # noqa: BLE001
                pass
        return trading_date_str(market)

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
        market = market_for_ticker(ticker)
        trading_date = self._trading_date_for(ticker)

        # Fast path: fresh on disk, no lock needed.
        fresh = self._try_read_fresh(
            ticker, market, trading_date, key, csv_path, meta_path
        )
        if fresh is not None:
            return fresh

        # Slow path: serialize per key so only one thread fetches.
        with self._lock_for(key):
            # Double-check: another thread may have populated it while we waited.
            fresh = self._try_read_fresh(
                ticker, market, trading_date, key, csv_path, meta_path
            )
            if fresh is not None:
                return fresh

            # We're the leader: fetch fresh (may raise -> caller handles).
            df = self._fetch(ticker, period, interval)
            try:
                self._write(
                    csv_path, meta_path, df, trading_date,
                    ticker=ticker, market=market,
                    period=period, interval=interval,
                )
            except Exception as exc:  # noqa: BLE001 - cache write best-effort
                logger.warning("cache write failed for %s: %s", ticker, exc)
            logger.info(
                "cache MISS key=%s market=%s symbol=%s cache_age=new "
                "latest_cached_ts=%s latest_provider_ts=%s trading_date=%s",
                key, market, ticker, _latest_index_ts(df),
                self._provider_ts(ticker), trading_date,
            )
            return df

    def read_cached_only(
        self, ticker: str, period: str = "1y", interval: str = "1d"
    ) -> Optional[pd.DataFrame]:
        """Return whatever is cached on disk WITHOUT ever fetching.

        Unlike :meth:`get`, this never triggers a network call: it returns the
        cached DataFrame if a cache file exists (regardless of TTL/freshness),
        or ``None`` when nothing is cached. Used by latency-sensitive,
        best-effort callers (e.g. simulated order pricing) that must not block
        on a slow/blocked data provider. Freshness is the warmer's job; a
        slightly stale cached close is far better than a multi-second stall or
        a timeout on a simulated trade.
        """
        key = self._key(ticker, period, interval)
        csv_path, _meta_path = self._paths(key)
        if not csv_path.exists():
            return None
        try:
            return self._read(csv_path)
        except Exception as exc:  # noqa: BLE001 - corrupt entry -> None
            logger.warning("cached-only read failed for %s: %s", ticker, exc)
            return None

    def _try_read_fresh(
        self, ticker: str, market: str, trading_date: str,
        key: str, csv_path: Path, meta_path: Path,
    ) -> Optional[pd.DataFrame]:
        """Return cached data if present and fresh, else None.

        Freshness requires: within TTL, matching trading date, and (when the
        provider hook is wired) no newer provider candle. Every hit/miss is
        logged with key/age/market/symbol/cached+provider timestamps (req 6).
        """
        meta = self._read_meta(meta_path)
        if meta is None:
            return None
        fetched_at = float(meta.get("fetched_at", 0))
        age = self._clock() - fetched_at
        cached_ts = meta.get("latest_ts")
        cached_trading_date = meta.get("trading_date")
        settled_date = meta.get("settled_date")
        provider_ts = self._provider_ts(ticker)

        reason = None
        if not (0 <= age < self._ttl_seconds()):
            reason = "ttl_expired"
        elif cached_trading_date and cached_trading_date != trading_date:
            # A new trading session has begun since we fetched: re-fetch now to
            # pick up the new day's data (unchanged behavior).
            reason = "trading_day_rolled"
        elif (
            settled_date
            and cached_trading_date
            and settled_date < cached_trading_date
            and age >= _LAG_REFETCH_MIN_S
        ):
            # We fetched FOR this session but the provider only had the prior
            # day's settled close (it returned an unsettled NaN bar for today).
            # Once today's close lands, a re-fetch picks it up. Bounded by
            # _LAG_REFETCH_MIN_S so a provider that keeps returning NaN can't
            # cause a per-request fetch storm. This fixes the "yesterday's close
            # served under today's date" staleness.
            reason = "close_not_yet_settled"
        elif provider_ts and cached_ts and provider_ts > cached_ts:
            reason = "newer_provider_candle"

        if reason is not None:
            logger.info(
                "cache MISS key=%s market=%s symbol=%s cache_age=%.1f "
                "latest_cached_ts=%s latest_provider_ts=%s trading_date=%s "
                "cached_trading_date=%s reason=%s",
                key, market, ticker, age, cached_ts, provider_ts,
                trading_date, cached_trading_date, reason,
            )
            return None

        try:
            df = self._read(csv_path)
        except Exception as exc:  # noqa: BLE001 - corrupt entry -> refetch
            logger.warning("cache read failed for %s: %s", ticker, exc)
            return None

        logger.info(
            "cache HIT key=%s market=%s symbol=%s cache_age=%.1f "
            "latest_cached_ts=%s latest_provider_ts=%s trading_date=%s",
            key, market, ticker, age, cached_ts, provider_ts, trading_date,
        )
        return df

    def _provider_ts(self, ticker: str) -> Optional[str]:
        if self._latest_provider is None:
            return None
        try:
            return self._latest_provider(ticker)
        except Exception:  # noqa: BLE001 - probe is best-effort
            return None

    # -- introspection (for /v1/debug/cache) ------------------------------

    def entries(self) -> List[dict]:
        """List cached entries with age / symbol / market / latest candle ts."""
        out: List[dict] = []
        for meta_path in self._dir.glob("*.meta.json"):
            meta = self._read_meta(meta_path)
            if meta is None:
                continue
            fetched_at = float(meta.get("fetched_at", 0))
            ticker = meta.get("ticker", "")
            out.append({
                "cache_key": meta_path.stem.replace(".meta", ""),
                "symbol": ticker,
                "market": meta.get("market")
                or (market_for_ticker(ticker) if ticker else None),
                "age_seconds": round(self._clock() - fetched_at, 1),
                "fetched_at": fetched_at,
                "trading_date": meta.get("trading_date"),
                "latest_candle_ts": meta.get("latest_ts"),
                "period": meta.get("period"),
                "interval": meta.get("interval"),
            })
        return out

    def clear(self, symbol: Optional[str] = None,
              market: Optional[str] = None) -> int:
        """Clear cache entries.

        * No args -> clear everything.
        * ``symbol`` -> clear entries whose ticker matches (case-insensitive,
          exact or suffix-stripped).
        * ``market`` -> clear entries whose market code matches.
        Returns the number of entries removed.
        """
        removed = 0
        sym = (symbol or "").upper().strip() or None
        mkt = (market or "").upper().strip() or None
        for meta_path in list(self._dir.glob("*.meta.json")):
            meta = self._read_meta(meta_path) or {}
            ticker = str(meta.get("ticker", "")).upper()
            mcode = str(
                meta.get("market") or (market_for_ticker(ticker) if ticker
                                       else "")
            ).upper()
            if sym is not None:
                # Keep entries that do NOT match the symbol.
                keep = not (ticker == sym or ticker.split(".")[0] == sym)
            elif mkt is not None:
                keep = mcode != mkt
            else:
                keep = False  # clear-all
            if not keep:
                key = meta_path.name[:-len(".meta.json")]
                csv_path = meta_path.parent / f"{key}.csv"
                for p in (meta_path, csv_path):
                    try:
                        p.unlink()
                        removed += 1 if p == meta_path else 0
                    except OSError:
                        pass
        if sym is None and mkt is None:
            # Also sweep any stray files (e.g. orphan CSVs) on clear-all.
            for p in self._dir.glob("*"):
                try:
                    p.unlink()
                except OSError:
                    pass
        return removed

    # -- internals ---------------------------------------------------------

    def _read_meta(self, meta_path: Path) -> Optional[dict]:
        if not meta_path.exists():
            return None
        try:
            return json.loads(meta_path.read_text())
        except (ValueError, OSError):
            return None

    def _read(self, csv_path: Path) -> pd.DataFrame:
        df = pd.read_csv(csv_path, index_col=0, parse_dates=True)
        if df.empty:
            raise ValueError("empty cached frame")
        # Defense-in-depth against a poisoned cache file. A frame that ever got
        # written from a multi-ticker yfinance response carries DUPLICATE field
        # columns (e.g. several 'Close' columns) or has lost the canonical OHLCV
        # names. Reading it back would let df['Close'] resolve to a 2-D slice
        # and serve another symbol's price (the "prices change after a while"
        # bug). Treat such a file as corrupt so the caller re-fetches cleanly.
        needed = {"Open", "High", "Low", "Close", "Volume"}
        # Known optional columns some providers add (kept; everything else is a
        # red flag for a multi-ticker bleed).
        allowed_extra = {"Adj Close", "Dividends", "Stock Splits", "Capital Gains"}
        cols = [str(c) for c in df.columns]
        # pandas renames literal duplicate headers on read (Close -> Close.1),
        # so the multi-ticker bleed shows up as both a '.N' suffix AND as an
        # unexpected column outside the OHLCV/allowed set.
        if len(set(cols)) != len(cols):
            raise ValueError(f"corrupt cached frame (duplicate columns): {cols}")
        if not needed.issubset(set(cols)):
            raise ValueError(f"corrupt cached frame (missing OHLCV): {cols}")
        unexpected = set(cols) - needed - allowed_extra
        if unexpected:
            # e.g. {'Close.1'} from a flattened multi-ticker frame.
            raise ValueError(
                f"corrupt cached frame (unexpected columns {unexpected}): {cols}"
            )
        return df

    def _write(self, csv_path: Path, meta_path: Path, df: pd.DataFrame,
               trading_date: str, *, ticker: str = "", market: str = "",
               period: str = "", interval: str = "") -> None:
        df.to_csv(csv_path)
        # ``trading_date`` is the session we FETCHED FOR (clock-derived). We
        # also record ``settled_date`` = the date of the newest row that has a
        # usable Close. They differ when the provider returns an unsettled
        # (NaN-close) bar for today: we fetched FOR today but only have
        # yesterday's settled close. The freshness check uses this gap to retry
        # (bounded) until today's close lands, instead of freezing yesterday's
        # price under today's date (the "one day stale" bug).
        meta = {
            "fetched_at": self._clock(),
            "trading_date": trading_date,
            "settled_date": _settled_trading_date(df),
            "latest_ts": _latest_index_ts(df),
            "ticker": ticker,
            "market": market,
            "period": period,
            "interval": interval,
        }
        meta_path.write_text(json.dumps(meta))
        # A fresh OHLCV write changes the market's data-freshness timestamp, so
        # drop the memoized freshness-probe results that the screener-cache
        # staleness check reads (otherwise a new candle could go undetected for
        # up to the probe TTL). Imported lazily to avoid an import cycle.
        try:
            from .screener_cache.service import (
                invalidate_freshness_probe_cache,
            )
            invalidate_freshness_probe_cache()
        except Exception:  # noqa: BLE001 - never let cache write break on this
            pass


def make_cached_fetcher(
    inner: InnerFetcher,
    cache_dir: Optional[Path | str] = None,
    ttl_seconds: Optional["int | Callable[[], int]"] = None,
    clock: Callable[[], float] = time.time,
    latest_provider_timestamp: Optional[LatestProviderTimestamp] = None,
    now_provider: Optional[Callable[[str], object]] = None,
) -> Callable[[str, str, str], pd.DataFrame]:
    """Build a `(ticker, period, interval) -> df` fetcher backed by disk cache."""
    cache = OhlcvCache(
        inner, cache_dir, ttl_seconds, clock,
        latest_provider_timestamp=latest_provider_timestamp,
        now_provider=now_provider,
    )
    def fetcher(
        ticker: str, period: str = "1y", interval: str = "1d"
    ) -> pd.DataFrame:
        return cache.get(ticker, period, interval)

    # Expose the backing cache so latency-sensitive callers can read the cached
    # close without forcing a network fetch (see OhlcvCache.read_cached_only).
    fetcher.cache = cache  # type: ignore[attr-defined]
    return fetcher
