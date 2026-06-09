"""Snapshot scheduler (Phase E).

A dependency-free background refresher that rebuilds the *global* snapshot
sections (indices / rotation / radar / morning brief / daily / multibagger /
watchlist AI) on their own cadences so most app requests hit a warm cache and
never trigger Yahoo.

  * Uses a single daemon thread with a small tick loop (no external scheduler).
  * Each section is forced past its own TTL on its cadence via
    ``SnapshotService.dashboard(market, force=...)`` section calls.
  * Best-effort: a failing refresh keeps the previous snapshot (Phase N).
  * ``start()`` / ``stop()`` are idempotent and test-friendly; the tick can be
    driven manually via :meth:`tick` for deterministic tests.

Per-user portfolio/watchlist snapshots are intentionally NOT scheduled here —
they're cheap, user-specific, and built on demand with their own TTL.
"""

from __future__ import annotations

import threading
import time
from typing import Callable, Dict, List, Optional

from ..models import Market
from . import cache as ttl
from .service import SnapshotService

# Refresh cadences (seconds). Morning Brief / Watchlist / Multibagger are daily
# in TTL terms but we re-evaluate them on a coarse cadence so a market-open
# refresh lands promptly; the section TTL still prevents needless recompute.
CADENCE_INDICES = ttl.TTL_INDICES          # 1 min
CADENCE_PORTFOLIO = ttl.TTL_PORTFOLIO      # 5 min (advisory; no global build)
CADENCE_RADAR = ttl.TTL_RADAR              # 15 min
CADENCE_ROTATION = ttl.TTL_ROTATION        # 15 min
CADENCE_MARKET_OPEN = 60 * 60              # hourly check for "market open" work


class SnapshotScheduler:
    def __init__(
        self,
        service: SnapshotService,
        *,
        markets: Optional[List[Market]] = None,
        clock: Callable[[], float] = time.monotonic,
        tick_seconds: float = 5.0,
        publisher=None,
        publish_on_refresh: bool = True,
        invalidate_cdn: bool = False,
    ) -> None:
        self._svc = service
        self._markets = markets or [Market.US]
        # Phase D: when a publisher is wired, every tick that refreshed any
        # section publishes the new snapshots to the CDN. Publishing NEVER
        # happens on a user request — only here in the scheduler.
        self._publisher = publisher
        self._publish_on_refresh = publish_on_refresh
        self._invalidate_cdn = invalidate_cdn
        self.last_publish = None
        self._clock = clock
        self._tick_seconds = tick_seconds
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._lock = threading.Lock()
        # task name -> (cadence, last_run, fn)
        self._last_run: Dict[str, float] = {}
        self._tasks: Dict[str, float] = {
            "indices": CADENCE_INDICES,
            "rotation": CADENCE_ROTATION,
            "radar": CADENCE_RADAR,
            "market_open": CADENCE_MARKET_OPEN,
        }

    # -- lifecycle ----------------------------------------------------------
    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._run, name="snapshot-scheduler", daemon=True
        )
        self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        t = self._thread
        if t and t.is_alive():
            t.join(timeout=timeout)
        self._thread = None

    def _run(self) -> None:
        while not self._stop.is_set():
            self.tick()
            self._stop.wait(self._tick_seconds)

    # -- one scheduling pass (also callable directly in tests) -------------
    def tick(self, *, now: Optional[float] = None) -> List[str]:
        """Run any tasks whose cadence elapsed. Returns the task names run."""
        ran: List[str] = []
        t = now if now is not None else self._clock()
        for name, cadence in self._tasks.items():
            last = self._last_run.get(name, -1e18)
            if t - last >= cadence:
                with self._lock:
                    self._last_run[name] = t
                try:
                    self._run_task(name)
                    ran.append(name)
                except Exception:  # noqa: BLE001 — best effort
                    pass
        # Phase D: publish to CDN after refreshing (scheduler-only).
        if ran and self._publisher is not None and self._publish_on_refresh:
            try:
                self.last_publish = self._publisher.publish(
                    invalidate=self._invalidate_cdn
                )
            except Exception:  # noqa: BLE001 — best effort
                pass
        return ran

    def _run_task(self, name: str) -> None:
        svc = self._svc
        if name == "indices":
            svc._section(  # force a fresh indices section
                "indices", ttl.TTL_INDICES,
                lambda: {"indices": svc_dump(svc._indices)} if svc._indices else None,
                force=True,
            )
        elif name == "rotation":
            svc._section(
                "rotation", ttl.TTL_ROTATION,
                lambda: _dump(svc._rotation()) if svc._rotation else None,
                force=True,
            )
        elif name == "radar":
            svc._section(
                "radar", ttl.TTL_RADAR,
                lambda: _dump(svc._opportunities()) if svc._opportunities else None,
                force=True,
            )
        elif name == "market_open":
            # Rebuild the daily/market-open sections + per-market dashboards.
            for mk in self._markets:
                try:
                    svc.dashboard(mk, force=True)
                except Exception:  # noqa: BLE001
                    pass


def _dump(obj):  # local import-light helper mirror
    from .service import _dump as _d
    return _d(obj)


def svc_dump(provider):
    if provider is None:
        return None
    return _dump(provider())
