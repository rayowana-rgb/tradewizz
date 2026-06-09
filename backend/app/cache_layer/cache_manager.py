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
from typing import Callable, Dict, Optional, TypeVar

from .ttl_cache import TTLCache

T = TypeVar("T")

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
