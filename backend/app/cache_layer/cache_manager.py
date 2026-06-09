"""Shared cache manager: namespaced TTL caches + stampede protection + metrics.

One :class:`CacheManager` instance is shared by Morning Brief, Global Rotation
and Opportunity Radar. Each *namespace* (e.g. ``"morning_brief"``) has its own
:class:`~app.cache.ttl_cache.TTLCache` and its own hit/miss counters.

Stampede protection
-------------------
``get_or_build(namespace, key, builder)`` guarantees that, for a given
``(namespace, key)``, only ONE thread runs ``builder()`` at a time. Concurrent
callers block on a per-key lock and, once the first build lands in the cache,
receive that same cached value (counted as hits) instead of rebuilding.

Metrics
-------
Per namespace we track ``hits`` and ``misses``. ``metrics()`` returns a flat
dict shaped for ``GET /v1/system/cache`` (e.g. ``morning_brief_hits``).
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from datetime import date, datetime
from typing import Callable, Dict, Generic, Optional, TypeVar

from .freshness import FreshnessDecision, evaluate as evaluate_freshness
from .ttl_cache import TTLCache

T = TypeVar("T")


@dataclass(frozen=True)
class _Envelope(Generic[T]):
    """What we actually store for freshness-aware entries."""

    value: T
    trading_date: date
    cached_at_epoch: float


@dataclass(frozen=True)
class CacheResult(Generic[T]):
    """Freshness-aware lookup outcome returned to scoring/display callers.

    ``value`` is ``None`` only when nothing usable exists (caller should return
    a partial-unavailable response). ``usable_as_fresh`` is the gate that
    scoring / radar / brief / watchlist / rotation / notifications MUST honour:
    never rank or alert on a result where this is False.
    """

    value: Optional[T]
    cached: bool          # value came from the cache (vs a fresh build)
    decision: FreshnessDecision

    @property
    def usable_as_fresh(self) -> bool:
        return self.decision.usable_as_fresh and self.value is not None

    @property
    def usable_as_display(self) -> bool:
        return self.decision.usable_as_display and self.value is not None

    @property
    def stale(self) -> bool:
        return self.decision.stale

    @property
    def fallback(self) -> bool:
        return self.decision.fallback

    @property
    def freshness(self) -> str:
        return self.decision.freshness if self.value is not None else "unavailable"

# Default TTLs (seconds) per namespace, per the cache spec.
DEFAULT_TTLS: Dict[str, float] = {
    "morning_brief": 15 * 60,   # 15 minutes
    "rotation": 15 * 60,        # 15 minutes
    "radar": 5 * 60,            # 5 minutes
}


class _NamespaceState:
    __slots__ = ("cache", "hits", "misses", "key_locks", "guard")

    def __init__(self, ttl: float) -> None:
        self.cache = TTLCache(ttl=ttl)
        self.hits = 0
        self.misses = 0
        # Per-key build locks (stampede protection) + a guard for the dict.
        self.key_locks: Dict[str, threading.Lock] = {}
        self.guard = threading.Lock()


class CacheManager:
    """Namespaced TTL caches with stampede protection and hit/miss metrics."""

    def __init__(self, ttls: Optional[Dict[str, float]] = None) -> None:
        merged = dict(DEFAULT_TTLS)
        if ttls:
            merged.update(ttls)
        self._ns: Dict[str, _NamespaceState] = {
            name: _NamespaceState(ttl) for name, ttl in merged.items()
        }
        self._metrics_lock = threading.Lock()

    # -- internals -------------------------------------------------------
    def _state(self, namespace: str) -> _NamespaceState:
        st = self._ns.get(namespace)
        if st is None:
            # Unknown namespaces get a default 5-minute TTL so the manager
            # never raises on a typo'd name.
            st = _NamespaceState(ttl=DEFAULT_TTLS.get(namespace, 5 * 60))
            self._ns[namespace] = st
        return st

    def _key_lock(self, st: _NamespaceState, key: str) -> threading.Lock:
        with st.guard:
            lock = st.key_locks.get(key)
            if lock is None:
                lock = threading.Lock()
                st.key_locks[key] = lock
            return lock

    # -- public API ------------------------------------------------------
    def get_or_build(
        self,
        namespace: str,
        key: str,
        builder: Callable[[], T],
    ) -> "tuple[T, bool]":
        """Return ``(value, cached)`` for ``(namespace, key)``.

        ``cached`` is ``True`` when the value came from the TTL cache (a hit)
        and ``False`` when ``builder()`` was run to populate it (a miss). Only
        one thread per key runs ``builder()``; the rest wait and get the hit.
        """
        st = self._state(namespace)

        # Fast path: live cache hit, no locking of the builder.
        value = st.cache.get(key)
        if value is not None:
            self._bump_hit(st)
            return value, True

        # Slow path: serialize builds per key (stampede protection).
        lock = self._key_lock(st, key)
        with lock:
            # Another thread may have built it while we waited.
            value = st.cache.get(key)
            if value is not None:
                self._bump_hit(st)
                return value, True
            built = builder()
            st.cache.set(key, built)
            self._bump_miss(st)
            return built, False

    def get_or_build_fresh(
        self,
        namespace: str,
        key: str,
        builder: Callable[[], T],
        market,
        *,
        force: bool = False,
        now: Optional[datetime] = None,
        now_epoch: Optional[float] = None,
        trading_date: Optional[date] = None,
    ) -> "CacheResult[T]":
        """Freshness + trading-date-aware get/build.

        Unlike :meth:`get_or_build`, this never serves a TTL hit blindly. It
        evaluates the entry against the trading-date freshness policy:

          * If a cached entry is **fresh** (``usable_as_fresh``), return it.
          * Otherwise rebuild (stampede-protected). On success, cache + return
            the fresh value.
          * If the rebuild raises (provider down) fall back to the cached
            entry **only when it may be displayed** — marked
            ``stale``/``fallback`` — and never as fresh. If nothing is usable,
            return a result with ``value=None`` (partial unavailable).

        ``trading_date`` lets the caller pin the trading date a fresh build is
        tagged with; otherwise the market's current trading date is used.
        """
        from ..market_session import current_trading_date

        st = self._state(namespace)
        if force:
            st.cache.pop(key)

        env: Optional[_Envelope] = st.cache.get(key)
        decision = self._evaluate(market, env, now=now, now_epoch=now_epoch)

        # Fresh cache hit -> serve it.
        if env is not None and decision.usable_as_fresh:
            self._bump_hit(st)
            return CacheResult(value=env.value, cached=True, decision=decision)

        # Need a (re)build. Serialize per key.
        lock = self._key_lock(st, key)
        with lock:
            # Re-check: another thread may have built a fresh entry.
            env = st.cache.get(key)
            decision = self._evaluate(
                market, env, now=now, now_epoch=now_epoch
            )
            if env is not None and decision.usable_as_fresh:
                self._bump_hit(st)
                return CacheResult(
                    value=env.value, cached=True, decision=decision
                )

            try:
                built = builder()
            except Exception:  # noqa: BLE001 - provider failed; try fallback
                self._bump_miss(st)
                if env is not None and decision.usable_as_display:
                    # Display-only stale fallback (NEVER usable_as_fresh).
                    return CacheResult(
                        value=env.value, cached=True, decision=decision
                    )
                # Nothing usable -> partial unavailable.
                return CacheResult(
                    value=None, cached=False, decision=decision
                )

            td = trading_date or current_trading_date(
                market, now if now is not None else None
            )
            cached_at = (
                now_epoch if now_epoch is not None
                else (now.timestamp() if now is not None else time.time())
            )
            new_env = _Envelope(
                value=built, trading_date=td, cached_at_epoch=cached_at
            )
            st.cache.set(key, new_env)
            self._bump_miss(st)
            fresh = self._evaluate(
                market, new_env, now=now, now_epoch=now_epoch
            )
            return CacheResult(value=built, cached=False, decision=fresh)

    def _evaluate(
        self, market, env: Optional[_Envelope], *, now=None, now_epoch=None
    ) -> FreshnessDecision:
        return evaluate_freshness(
            market,
            entry_trading_date=env.trading_date if env else None,
            entry_cached_at_epoch=env.cached_at_epoch if env else None,
            now=now,
            now_epoch=now_epoch,
        )

    def invalidate(self, namespace: str, key: Optional[str] = None) -> None:
        st = self._ns.get(namespace)
        if st is None:
            return
        if key is None:
            st.cache.clear()
        else:
            st.cache.pop(key)

    def clear_all(self) -> None:
        for st in self._ns.values():
            st.cache.clear()

    def reset_metrics(self) -> None:
        with self._metrics_lock:
            for st in self._ns.values():
                st.hits = 0
                st.misses = 0

    def metrics(self) -> Dict[str, int]:
        """Flat ``{<namespace>_hits, <namespace>_misses}`` for the API."""
        out: Dict[str, int] = {}
        with self._metrics_lock:
            for name, st in self._ns.items():
                out[f"{name}_hits"] = st.hits
                out[f"{name}_misses"] = st.misses
        return out

    # -- counters --------------------------------------------------------
    def _bump_hit(self, st: _NamespaceState) -> None:
        with self._metrics_lock:
            st.hits += 1

    def _bump_miss(self, st: _NamespaceState) -> None:
        with self._metrics_lock:
            st.misses += 1


# Process-wide singleton (one shared manager for all features).
_manager: Optional[CacheManager] = None
_singleton_lock = threading.Lock()


def get_cache_manager() -> CacheManager:
    global _manager
    if _manager is None:
        with _singleton_lock:
            if _manager is None:
                _manager = CacheManager()
    return _manager
