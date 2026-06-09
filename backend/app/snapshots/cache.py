"""Server-side snapshot cache (Phase D).

A tiny, dependency-free, thread-safe JSON file cache under ``data/snapshots/``.

  * ``get(name)``      -> (payload, age_seconds) or (None, None) on miss.
  * ``is_fresh(...)``  -> True while within the section TTL.
  * ``put(name, ...)`` -> persist a payload (in-memory + file).

Reliability (Phase N): callers use :meth:`put_guarded` so a refresh that
produced ``None`` / an empty mapping / an empty list never overwrites a valid
existing snapshot. The previous good snapshot is kept instead.
"""

from __future__ import annotations

import json
import os
import threading
import time
from typing import Any, Dict, Optional, Tuple

# --------------------------------------------------------------------------- #
# TTLs (seconds). These mirror the task's TTL table. They gate the *server*
# snapshot files; the Flutter Hive layer has its own (shorter) display TTLs.
# --------------------------------------------------------------------------- #
TTL_INDICES = 60          # 1 minute
TTL_PORTFOLIO = 5 * 60    # 5 minutes
TTL_RADAR = 15 * 60       # 15 minutes
TTL_ROTATION = 15 * 60    # 15 minutes
TTL_MORNING_BRIEF = 24 * 60 * 60   # 1 day
TTL_DAILY_PICKS = 24 * 60 * 60     # 1 day
TTL_MULTIBAGGER = 24 * 60 * 60     # 1 day
TTL_WATCHLIST_AI = 24 * 60 * 60    # 1 day
TTL_NOTIFICATIONS = 5 * 60         # 5 minutes

# Whole-document TTL used for the cache freshness gate. We take the *shortest*
# meaningful section TTL of each document so a stale dashboard is refreshed at
# the indices cadence; individual sections are still rebuilt only when their own
# TTL elapsed inside the service.
TTL_DASHBOARD = TTL_INDICES
TTL_WATCHLIST = TTL_ROTATION


def _default_dir() -> str:
    env = os.environ.get("TRADEWIZZ_SNAPSHOT_DIR")
    if env:
        return env
    # backend/data/snapshots
    here = os.path.dirname(os.path.dirname(os.path.dirname(__file__)))
    return os.path.join(here, "data", "snapshots")


def _is_empty(payload: Any) -> bool:
    """A payload that must NOT overwrite a valid snapshot (Phase N)."""
    if payload is None:
        return True
    if isinstance(payload, dict):
        if not payload:
            return True
        # An explicit error response is treated as empty for overwrite safety.
        if payload.get("error") is not None:
            return True
        return False
    if isinstance(payload, (list, tuple, str)):
        return len(payload) == 0
    return False


class SnapshotCache:
    """Thread-safe JSON snapshot store backed by ``data/snapshots/``."""

    def __init__(self, directory: Optional[str] = None,
                 clock=time.time) -> None:
        self._dir = directory or _default_dir()
        self._clock = clock
        self._lock = threading.RLock()
        # name -> (stored_at, payload)
        self._mem: Dict[str, Tuple[float, Any]] = {}
        os.makedirs(self._dir, exist_ok=True)
        self._load_existing()

    # -- paths --------------------------------------------------------------
    def _path(self, name: str) -> str:
        safe = name.replace("/", "_")
        return os.path.join(self._dir, f"{safe}.json")

    def _load_existing(self) -> None:
        try:
            for fn in os.listdir(self._dir):
                if not fn.endswith(".json"):
                    continue
                name = fn[:-5]
                try:
                    with open(os.path.join(self._dir, fn), "r") as fh:
                        wrapped = json.load(fh)
                    stored_at = float(wrapped.get("_stored_at", 0.0))
                    self._mem[name] = (stored_at, wrapped.get("payload"))
                except Exception:  # noqa: BLE001
                    continue
        except FileNotFoundError:
            pass

    # -- reads --------------------------------------------------------------
    def get(self, name: str) -> Tuple[Optional[Any], Optional[float]]:
        """Return ``(payload, age_seconds)`` or ``(None, None)`` on miss."""
        with self._lock:
            entry = self._mem.get(name)
        if entry is None:
            return None, None
        stored_at, payload = entry
        return payload, max(0.0, self._clock() - stored_at)

    def age(self, name: str) -> Optional[float]:
        _, age = self.get(name)
        return age

    def is_fresh(self, name: str, ttl: float) -> bool:
        _, age = self.get(name)
        return age is not None and age < ttl

    def has(self, name: str) -> bool:
        with self._lock:
            return name in self._mem

    def size_bytes(self, name: str) -> int:
        try:
            return os.path.getsize(self._path(name))
        except OSError:
            return 0

    # -- writes -------------------------------------------------------------
    def put(self, name: str, payload: Any) -> None:
        stored_at = self._clock()
        with self._lock:
            self._mem[name] = (stored_at, payload)
        wrapped = {"_stored_at": stored_at, "payload": payload}
        tmp = self._path(name) + ".tmp"
        try:
            with open(tmp, "w") as fh:
                json.dump(wrapped, fh)
            os.replace(tmp, self._path(name))
        except Exception:  # noqa: BLE001 — memory copy still valid
            try:
                os.remove(tmp)
            except OSError:
                pass

    def put_guarded(self, name: str, payload: Any) -> bool:
        """Persist only if ``payload`` is non-empty (Phase N).

        Returns True if written, False if the existing snapshot was kept.
        """
        if _is_empty(payload):
            return False
        self.put(name, payload)
        return True

    def clear(self, name: Optional[str] = None) -> None:
        with self._lock:
            names = [name] if name else list(self._mem.keys())
            for n in names:
                self._mem.pop(n, None)
                try:
                    os.remove(self._path(n))
                except OSError:
                    pass

    def stats(self) -> Dict[str, Dict[str, Any]]:
        out: Dict[str, Dict[str, Any]] = {}
        with self._lock:
            for name, (stored_at, _payload) in self._mem.items():
                out[name] = {
                    "age_seconds": round(max(0.0, self._clock() - stored_at), 3),
                    "stored_at": stored_at,
                    "size_bytes": self.size_bytes(name),
                }
        return out
