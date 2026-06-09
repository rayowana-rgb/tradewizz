"""A small, thread-safe TTL cache (no external dependency).

Behaviourally equivalent to ``cachetools.TTLCache`` for our needs: entries
expire after ``ttl`` seconds and the store is bounded by ``maxsize`` (oldest
entry evicted first). Time is injectable so tests can simulate TTL expiry
without sleeping.

The cache is value-only; stampede protection (the "only one rebuild" rule) is
handled one layer up in :class:`~app.cache.cache_manager.CacheManager`, which
owns the per-key locks and the hit/miss counters.
"""

from __future__ import annotations

import threading
import time
from collections import OrderedDict
from typing import Callable, Optional, Tuple


class TTLCache:
    """Thread-safe mapping where entries expire after ``ttl`` seconds."""

    def __init__(
        self,
        ttl: float,
        maxsize: int = 256,
        timer: Callable[[], float] = time.monotonic,
    ) -> None:
        if ttl <= 0:
            raise ValueError("ttl must be positive")
        self._ttl = float(ttl)
        self._maxsize = int(maxsize)
        self._timer = timer
        self._lock = threading.Lock()
        # key -> (expires_at, value)
        self._store: "OrderedDict[str, Tuple[float, object]]" = OrderedDict()

    @property
    def ttl(self) -> float:
        return self._ttl

    def get(self, key: str):
        """Return the live value for ``key`` or ``None`` if missing/expired."""
        now = self._timer()
        with self._lock:
            item = self._store.get(key)
            if item is None:
                return None
            expires_at, value = item
            if expires_at <= now:
                # Expired: drop it so callers treat this as a miss.
                self._store.pop(key, None)
                return None
            # Mark as most-recently used.
            self._store.move_to_end(key)
            return value

    def set(self, key: str, value, ttl: Optional[float] = None) -> None:
        """Store ``value`` under ``key`` for ``ttl`` (defaults to cache TTL)."""
        expires_at = self._timer() + (self._ttl if ttl is None else float(ttl))
        with self._lock:
            self._store[key] = (expires_at, value)
            self._store.move_to_end(key)
            while len(self._store) > self._maxsize:
                self._store.popitem(last=False)

    def pop(self, key: str) -> None:
        with self._lock:
            self._store.pop(key, None)

    def clear(self) -> None:
        with self._lock:
            self._store.clear()

    def __len__(self) -> int:
        # Counts entries including any not-yet-purged expired ones.
        with self._lock:
            return len(self._store)
