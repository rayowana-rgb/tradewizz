"""Market-close screener caching service.

Behavior:
  * Market OPEN  -> never run heavy screening; return the latest saved snapshot
    (if any), flagged ``cached=true`` with a "using latest market-close result"
    reason. ``force_refresh`` is refused with a warning.
  * Market CLOSED -> if today's market-close snapshot already exists, return it
    (no rerun). Otherwise run the heavy screen once, save it, and return it.
    ``force_refresh=true`` forces a single fresh run + save (allowed only when
    closed).

The saved snapshot stays valid until the next market-close screening for the
same (market, cache-key). It does not expire mid-day and is not re-run just
because the app is reopened many times.

This module deliberately does not import or alter the scoring formula,
indicators, the Yahoo data source, the analysis engine, broker logic, or
portfolio logic. The heavy work is delegated to an injected ``run_screen``
callable so this layer stays a thin cache around the existing engine.
"""

from __future__ import annotations

import threading
import time as _time
from datetime import datetime, timezone
from typing import Callable, Dict, Optional, Tuple

from ..models import Market, ScreenerResult
from .store import ScreenerSnapshotRecord, ScreenerSnapshotStore

# --- Data-freshness probe cache --------------------------------------------- #
#
# ``latest_market_candle_ts`` / ``latest_market_write_ts`` scan EVERY cached
# OHLCV ``*.meta.json`` file on disk (tens of thousands across all markets) to
# find the newest candle / write timestamp. ``service.get`` calls these probes
# on the staleness-validation path, so every steady-state request (e.g. the
# Dashboard market overview) was re-reading ~50k+ small files from disk -- the
# dominant cost (multi-second latency) even though nothing was being fetched.
#
# These timestamps only change when the warmer/engine (re)writes the OHLCV
# cache, which happens at most a few times per minute, so a short TTL memo is
# safe: it never serves a snapshot built from data older than the probe knew,
# and at most delays freshness detection by ``_PROBE_TTL_SECONDS``.
_PROBE_TTL_SECONDS = 30.0
_PROBE_CACHE_GUARD = threading.Lock()
# key: (func_name, market_code, include_write_time) -> (expires_at, value)
_PROBE_CACHE: Dict[Tuple[str, str, bool], Tuple[float, Optional[str]]] = {}


def _probe_cache_get(key: Tuple[str, str, bool]) -> Tuple[bool, Optional[str]]:
    """Return ``(hit, value)`` for a cached probe result within its TTL."""
    now = _time.monotonic()
    with _PROBE_CACHE_GUARD:
        entry = _PROBE_CACHE.get(key)
        if entry is not None and entry[0] > now:
            return True, entry[1]
    return False, None


def _probe_cache_put(key: Tuple[str, str, bool], value: Optional[str]) -> None:
    with _PROBE_CACHE_GUARD:
        _PROBE_CACHE[key] = (_time.monotonic() + _PROBE_TTL_SECONDS, value)


def invalidate_freshness_probe_cache() -> None:
    """Drop all memoized freshness-probe results (call after a cache write)."""
    with _PROBE_CACHE_GUARD:
        _PROBE_CACHE.clear()

# --- Single-flight (thundering-herd) guard for CLOSED-market engine runs ---- #
#
# ``ScreenerCacheService`` is constructed per request in main.py, so any lock
# that protected the heavy engine run must be SHARED across instances or it
# would be useless. These module-level structures are that shared state:
#   * ``_RUN_LOCKS`` maps a (market, cache_key) pair to a dedicated lock so
#     concurrent requests for the SAME snapshot serialize on the SAME lock,
#     while requests for DIFFERENT snapshots stay fully parallel.
#   * ``_RUN_LOCKS_GUARD`` protects creation/lookup of those per-key locks.
#
# This guard ONLY applies to CLOSED-market engine runs (``_run_and_save``):
# when the market is OPEN we never run the engine for steady-state requests,
# so there is no herd to collapse there.
_RUN_LOCKS_GUARD = threading.Lock()
_RUN_LOCKS: Dict[Tuple[str, str], threading.Lock] = {}


def _run_lock_for(market_value: str, cache_key: str) -> threading.Lock:
    """Return the shared lock for a (market, cache_key), creating it once."""
    key = (market_value, cache_key)
    with _RUN_LOCKS_GUARD:
        lock = _RUN_LOCKS.get(key)
        if lock is None:
            lock = threading.Lock()
            _RUN_LOCKS[key] = lock
        return lock

# Imported as read-only helpers (no scoring/engine behavior changes).
from ..engine import _is_market_open, _market_now  # noqa: E402
from ..market_session import trading_date_str  # noqa: E402

# Type of the cache-only "latest candle timestamp" probe: market code
# (e.g. "IDX") -> ISO timestamp string of the newest OHLCV candle currently in
# the cache for that market, or None when nothing is cached / unknown.
LatestDataTimestamp = Callable[[str], Optional[str]]


def latest_market_candle_ts(
    market_code: str, *, include_write_time: bool = False
) -> Optional[str]:
    """Newest "data freshness" timestamp for a market (cache-only, no fetch).

    Reads the same on-disk OHLCV cache that ``/analyze`` uses, via the live
    cache registry, inspecting only already-cached metadata (never triggers a
    network fetch).

    The freshness signal is the latest **candle timestamp** (``latest_ts``),
    i.e. the trading day the data is FOR. This is what should invalidate a
    saved snapshot: a new trading day's candle means new data to screen.

    The cache **write time** (``fetched_at``) is deliberately NOT used by
    default. It changes every time ANY symbol's cache file is (re)written --
    e.g. someone opening a stock detail page, or the screen run itself writing
    fresh cache -- even though the underlying trading day has not changed. Using
    it made a CLOSED-session snapshot rebuild on almost every request, and each
    rebuild re-screened the universe with whatever yfinance availability
    existed at that instant, so the result set (which symbols succeed vs. get
    skipped) and the ranking kept shifting between runs even though the market
    was equally closed. That is the "screener results keep changing" bug.
    ``include_write_time=True`` restores the old behavior for callers that
    explicitly want intraday write-time sensitivity.

    Returns the maximum across all cached symbols for the market (normalized to
    ISO-8601 UTC), or ``None`` when nothing is cached yet.
    """
    # Imported lazily to avoid an import cycle (cache <-> engine <-> service).
    from ..cache import all_caches  # noqa: WPS433

    want = (market_code or "").upper().strip()
    ck = ("candle", want, bool(include_write_time))
    hit, cached = _probe_cache_get(ck)
    if hit:
        return cached
    best: Optional[str] = None
    for cache in all_caches():
        try:
            entries = cache.entries()
        except Exception:  # noqa: BLE001 - never let a probe break /screen
            continue
        for entry in entries:
            mkt = str(entry.get("market") or "").upper()
            if want and mkt != want:
                continue
            candidates = [entry.get("latest_candle_ts")]
            if include_write_time:
                candidates.append(_epoch_to_iso_utc(entry.get("fetched_at")))
            for raw in candidates:
                norm = _to_iso_utc(raw)
                if norm and (best is None or norm > best):
                    best = norm
    _probe_cache_put(ck, best)
    return best


def latest_market_write_ts(market_code: str) -> Optional[str]:
    """Newest cache **write time** (``fetched_at``) for a market, ISO UTC.

    Distinct from :func:`latest_market_candle_ts`: this returns ONLY the cache
    write timestamps (when the OHLCV files were last (re)written), never the
    candle trading-date timestamps. The Opsi A intraday-refresh check needs a
    pure write-time signal so it can detect a fresher post-close price fetch on
    the SAME trading day without being confused by today's daily candle
    timestamp (whose UTC clock-time can land later than the screen's wall-clock
    generation time -- the original "rebuild on every request" regression).

    Returns the maximum ``fetched_at`` across all cached symbols for the market
    (normalized to ISO-8601 UTC), or ``None`` when nothing is cached yet.
    """
    from ..cache import all_caches  # noqa: WPS433

    want = (market_code or "").upper().strip()
    ck = ("write", want, False)
    hit, cached = _probe_cache_get(ck)
    if hit:
        return cached
    best: Optional[str] = None
    for cache in all_caches():
        try:
            entries = cache.entries()
        except Exception:  # noqa: BLE001 - never let a probe break /screen
            continue
        for entry in entries:
            mkt = str(entry.get("market") or "").upper()
            if want and mkt != want:
                continue
            norm = _epoch_to_iso_utc(entry.get("fetched_at"))
            if norm and (best is None or norm > best):
                best = norm
    _probe_cache_put(ck, best)
    return best


def _epoch_to_iso_utc(epoch: object) -> Optional[str]:
    """Convert an epoch-seconds float to an ISO-8601 UTC string, or None."""
    try:
        secs = float(epoch)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return None
    if secs <= 0:
        return None
    return datetime.fromtimestamp(secs, tz=timezone.utc).isoformat()


def _to_iso_utc(value: object) -> Optional[str]:
    """Normalize an ISO timestamp string to ISO-8601 UTC (naive => UTC)."""
    dt = _parse_iso(value)
    if dt is None:
        return None
    return dt.isoformat()


def _parse_iso(value: object) -> Optional[datetime]:
    """Parse an ISO-8601 string to a tz-aware UTC datetime, or None.

    Naive timestamps (e.g. a tz-naive daily candle index) are treated as UTC
    so they remain comparable with tz-aware ``generated_at`` values.
    """
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

# Human-readable, stable copy used by both the API and the Flutter app.
# Minimum seconds the cache write-time must lead the snapshot's generated_at
# before the snapshot is considered stale (Opsi A). Guards against the screen
# run's OWN cache writes (made just before generated_at is stamped) triggering
# an immediate rebuild loop.
_WRITE_TIME_EPSILON_S = 0.5

REASON_OPEN = "Using latest market-close screening result"
NEXT_REFRESH_RULE = "Will refresh after next market close"
FORCE_REFRESH_DENIED = (
    "Screening refresh is only allowed after market close."
)


def market_status(market: Market, now: Optional[datetime] = None) -> str:
    """\"OPEN\" or \"CLOSED\" for the market at ``now`` (market-local)."""
    current = now if now is not None else _market_now(market)
    return "OPEN" if _is_market_open(market, current) else "CLOSED"


def market_date_str(market: Market, now: Optional[datetime] = None) -> str:
    """Trading date (YYYY-MM-DD) used as the snapshot date.

    Aligned with the OHLCV cache's trading-date keying so the screener snapshot
    rolls on the same boundary that ``/analyze`` data does (e.g. before the
    open it still maps to the prior trading session), avoiding open-boundary
    drift between the list and the detail page.
    """
    current = now if now is not None else _market_now(market)
    return trading_date_str(market, current)


def make_cache_key(
    *,
    category: str,
    limit: int,
    min_score: float,
    min_value_traded: float,
) -> str:
    """Cache key separating snapshots by category + result-affecting params.

    ``category`` is the comma-separated, normalized category filter ("" when no
    filter is applied). ``limit``/``min_score``/``min_value_traded`` change the
    result set, so they are folded into the key per the requirements.
    """
    cat = category or "_all"
    return (
        f"{cat}|limit={int(limit)}|min_score={float(min_score):g}"
        f"|min_value={float(min_value_traded):g}"
    )


class ScreenerCacheService:
    """Thin market-close cache around the heavy screening engine."""

    def __init__(
        self,
        store: ScreenerSnapshotStore,
        run_screen: Callable[[], ScreenerResult],
        *,
        now_provider: Optional[Callable[[Market], datetime]] = None,
        cold_open_live: bool = True,
        latest_data_timestamp: Optional[LatestDataTimestamp] = (
            latest_market_candle_ts
        ),
        latest_write_timestamp: Optional[
            Callable[[str], Optional[str]]
        ] = latest_market_write_ts,
    ):
        self._store = store
        self._run_screen = run_screen
        self._now_provider = now_provider
        # Cache-only probe for the newest cache WRITE time (Opsi A). Used to
        # detect a fresher price fetch on the SAME trading day. Injectable for
        # tests; None disables the intraday-refresh path.
        self._latest_write_timestamp = latest_write_timestamp
        # Cache-only probe used to detect that the underlying OHLCV/analyze
        # data refreshed AFTER a CLOSED snapshot was generated. When it reports
        # a newer candle than the saved snapshot, the snapshot is rebuilt so
        # /screen (and the dashboard top-movers that use it) track /analyze.
        # Defaults to the live cache registry probe; injectable for tests.
        self._latest_data_timestamp = latest_data_timestamp
        # When the market is OPEN but no snapshot has ever been saved for this
        # key (cold start), run the heavy screen ONCE without saving so the app
        # still shows results. The result is not persisted, so it does not
        # become "the market-close result" and no repeated market-hours screen
        # happens once a real snapshot exists. Disable for strict tests that
        # assert no screening at all during market hours.
        self._cold_open_live = cold_open_live

    def _now(self, market: Market) -> datetime:
        if self._now_provider is not None:
            return self._now_provider(market)
        return _market_now(market)

    def get(
        self,
        market: Market,
        cache_key: str,
        *,
        force_refresh: bool = False,
    ) -> ScreenerResult:
        now = self._now(market)
        status = market_status(market, now)
        today = market_date_str(market, now)

        if status == "OPEN":
            return self._serve_open(market, cache_key, status, force_refresh)

        # --- Market CLOSED ----------------------------------------------- #
        if force_refresh:
            # Allowed only when closed: run once, save, return fresh.
            return self._run_and_save(
                market, cache_key, status, today, force_refresh=True
            )

        # Reuse today's market-close snapshot if it already exists -- but only
        # if the underlying OHLCV/analyze data has not refreshed since it was
        # generated. If a newer candle is available (same market date), the
        # frozen snapshot would show stale prices while /analyze shows fresh
        # ones, so rebuild + re-save instead of serving it.
        existing = self._store.get_for_date(market.value, cache_key, today)
        if existing is not None:
            if self._data_is_newer_than(market, existing):
                return self._run_and_save(market, cache_key, status, today)
            # Opsi A: even on the SAME trading day, if the underlying OHLCV
            # cache was (re)written AFTER this snapshot was generated -- e.g.
            # a fresher post-close last price was fetched -- the frozen
            # snapshot would show stale prices (the GULA 640-vs-665 case).
            # Rebuild + re-save so /screen tracks /analyze. This only runs
            # while CLOSED (never during market hours), and the rebuild
            # advances the snapshot's generated_at past the cache write-time,
            # so it will not rebuild again until the NEXT fetch -- bounding
            # the work to at most one re-screen per data refresh.
            if self._data_written_after(market, existing):
                return self._run_and_save(market, cache_key, status, today)
            return self._from_record(existing, cached=True, status=status)

        # No snapshot for today yet -> run the heavy screen once and save it.
        return self._run_and_save(market, cache_key, status, today)

    # -- internals -------------------------------------------------------- #
    def _data_is_newer_than(
        self, market: Market, rec: ScreenerSnapshotRecord
    ) -> bool:
        """True when cached OHLCV data is for a NEWER TRADING DAY than the snapshot.

        Lightweight, cache-only check. The freshness signal is the latest cached
        candle's **trading DATE** vs. the snapshot's trading date
        (``rec.market_date``), NOT a raw-instant comparison.

        Why date, not instant (critical correctness fix): the probe returns a
        candle *timestamp* (the day the data is FOR -- e.g. today's daily candle,
        whose clock-time can land later in the UTC day than the snapshot's
        wall-clock *generation* time). The old ``candle_ts > generated_at``
        check therefore made today's OWN candle look "newer" than a snapshot
        generated earlier the same day, so EVERY CLOSED request rebuilt the
        whole universe. For IDX (~956 symbols) that was merely slow; for the
        ~12,767-symbol US universe it was catastrophic -- every /screen/us call
        re-ran a multi-minute live screen, hit Yahoo rate limits, and timed out,
        so the app's home screen rendered blank. A snapshot built for a given
        trading day must stay valid for that whole day; only a candle from a
        STRICTLY LATER trading day should invalidate it (next market close).

        Returns False (keep existing snapshot) whenever the comparison cannot be
        made -- no probe, no cached candle, or unparseable values -- so behavior
        is unchanged when validation is indeterminate.
        """
        if self._latest_data_timestamp is None:
            return False
        try:
            latest = self._latest_data_timestamp(market.value)
        except Exception:  # noqa: BLE001 - never let a probe break /screen
            return False
        if not latest:
            return False
        data_dt = _parse_iso(latest)
        if data_dt is None:
            return False
        # Map the candle instant to its market-local trading date, then compare
        # against the snapshot's recorded trading date (both YYYY-MM-DD strings).
        try:
            candle_trading_date = trading_date_str(market, data_dt)
        except Exception:  # noqa: BLE001 - never let date mapping break /screen
            return False
        snap_date = (rec.market_date or "").strip()
        if not snap_date or not candle_trading_date:
            return False
        return candle_trading_date > snap_date

    def _data_written_after(
        self, market: Market, rec: ScreenerSnapshotRecord
    ) -> bool:
        """True when cached OHLCV data was (re)written AFTER the snapshot ran.

        Opsi A intraday-refresh check (CLOSED-only). Uses the cache **write
        time** (``fetched_at``), not the candle trading date, so a fresher
        last-price fetch on the SAME trading day -- which leaves the trading
        date unchanged but updates the price -- still invalidates a frozen
        snapshot. Compared against the snapshot's ``generated_at`` (the instant
        the screen actually ran). A small epsilon avoids treating the screen's
        OWN cache writes (made microseconds before generated_at is stamped) as
        "newer", which would otherwise rebuild on every request.

        Returns False (keep existing snapshot) whenever the comparison cannot
        be made, so behavior is unchanged when the probe is indeterminate.
        """
        if self._latest_write_timestamp is None:
            return False
        try:
            latest = self._latest_write_timestamp(market.value)
        except Exception:  # noqa: BLE001 - never let a probe break /screen
            return False
        if not latest:
            return False
        written_dt = _parse_iso(latest)
        gen_dt = _parse_iso(rec.generated_at)
        if written_dt is None or gen_dt is None:
            return False
        # Require the data write to be meaningfully after generation so the
        # screen run's own cache writes don't trigger an immediate rebuild.
        return (written_dt - gen_dt).total_seconds() > _WRITE_TIME_EPSILON_S

    def _serve_open(
        self,
        market: Market,
        cache_key: str,
        status: str,
        force_refresh: bool,
    ) -> ScreenerResult:
        """Market open: never screen. Return the latest snapshot (any date)."""
        warning = FORCE_REFRESH_DENIED if force_refresh else None
        latest = self._store.latest(market.value, cache_key)
        if latest is not None:
            return self._from_record(
                latest, cached=True, status=status, warning=warning
            )
        # No saved snapshot ever produced for this key yet (cold start). If
        # allowed, run the heavy screen once WITHOUT saving so the app still
        # shows results; it is flagged cached=False (not a market-close result)
        # and is never persisted, so steady-state market-hours requests still
        # never re-screen once a snapshot exists.
        if self._cold_open_live:
            fresh = self._run_screen()
            fresh.cached = False
            fresh.market_status = status
            fresh.market_date = None
            fresh.next_refresh_rule = NEXT_REFRESH_RULE
            fresh.warning = warning or REASON_OPEN
            return fresh
        # Strict mode: never screen while open -> empty cached-style result.
        return ScreenerResult(
            market=market,
            matches=[],
            generated_at=self._now(market).isoformat(),
            total_count=0,
            returned_count=0,
            cached=True,
            market_status=status,
            market_date=None,
            next_refresh_rule=NEXT_REFRESH_RULE,
            warning=warning or REASON_OPEN,
        )

    def _run_and_save(
        self,
        market: Market,
        cache_key: str,
        status: str,
        market_date: str,
        *,
        force_refresh: bool = False,
    ) -> ScreenerResult:
        """Run the heavy engine once and persist the snapshot (CLOSED only).

        Single-flight: concurrent requests for the SAME (market, cache_key)
        serialize on a shared lock so the engine runs ONCE for the herd, not
        once per request. After acquiring the lock we re-check the store
        (double-checked locking): if another request already saved today's
        snapshot while we were waiting, we reuse it instead of re-running the
        engine. ``force_refresh`` skips that reuse (it is an explicit,
        CLOSED-only request for a brand-new run) but still holds the lock so
        two forced refreshes don't run the engine in parallel.
        """
        lock = _run_lock_for(market.value, cache_key)
        with lock:
            if not force_refresh:
                # Another request in the herd may have just saved this exact
                # snapshot for today while we waited on the lock -- reuse it
                # rather than re-running the heavy engine.
                existing = self._store.get_for_date(
                    market.value, cache_key, market_date
                )
                if existing is not None and not self._data_is_newer_than(
                    market, existing
                ) and not self._data_written_after(market, existing):
                    return self._from_record(
                        existing, cached=True, status=status
                    )
            fresh = self._run_screen()
            payload = fresh.model_dump(mode="json")
            rec = self._store.save(
                market=market.value,
                category=cache_key,
                market_date=market_date,
                market_status=status,
                payload=payload,
            )
            return self._from_record(rec, cached=False, status=status)

    def _from_record(
        self,
        rec: ScreenerSnapshotRecord,
        *,
        cached: bool,
        status: str,
        warning: Optional[str] = None,
    ) -> ScreenerResult:
        payload = rec.payload()
        result = ScreenerResult.model_validate(payload)
        result.cached = cached
        result.market_status = status
        result.market_date = rec.market_date
        result.generated_at = rec.generated_at
        result.next_refresh_rule = NEXT_REFRESH_RULE
        if warning is not None:
            result.warning = warning
        elif status == "OPEN":
            # Opened during market hours: explain the cached result.
            result.warning = REASON_OPEN
        return result
