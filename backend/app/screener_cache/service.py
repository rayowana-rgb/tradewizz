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

from datetime import datetime
from typing import Callable, Optional

from ..models import Market, ScreenerResult
from .store import ScreenerSnapshotRecord, ScreenerSnapshotStore

# Imported as read-only helpers (no scoring/engine behavior changes).
from ..engine import _is_market_open, _market_now  # noqa: E402

# Human-readable, stable copy used by both the API and the Flutter app.
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
    """Market-local calendar date (YYYY-MM-DD) used as the snapshot date."""
    current = now if now is not None else _market_now(market)
    return current.date().isoformat()


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
    ):
        self._store = store
        self._run_screen = run_screen
        self._now_provider = now_provider
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
            return self._run_and_save(market, cache_key, status, today)

        # Reuse today's market-close snapshot if it already exists.
        existing = self._store.get_for_date(market.value, cache_key, today)
        if existing is not None:
            return self._from_record(existing, cached=True, status=status)

        # No snapshot for today yet -> run the heavy screen once and save it.
        return self._run_and_save(market, cache_key, status, today)

    # -- internals -------------------------------------------------------- #
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
    ) -> ScreenerResult:
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
