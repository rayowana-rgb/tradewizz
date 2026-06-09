"""Snapshot engine (Phase 6 — offline-first architecture).

Aggregates the OUTPUT of the existing services (Morning Brief, Rotation, Radar,
Notifications, Auto Watchlist, Simulation, Portfolio Health / Manager) into a
single pre-computed JSON document per surface (dashboard / portfolio /
watchlist), cached server-side with per-section TTLs.

This package contains **no** scoring / ranking / accounting logic. It only
*calls* the existing services and *serializes* their pydantic results, so all
investment logic stays exactly where it already lives.
"""

from .cache import SnapshotCache  # noqa: F401
from .service import SnapshotService  # noqa: F401

__all__ = ["SnapshotService", "SnapshotCache"]
