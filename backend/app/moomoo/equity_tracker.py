"""Records real Moomoo account equity over time so the app can draw a
portfolio-growth chart.

There is no NAV-history endpoint in the OpenD SDK, so we build the series
ourselves from *real* observations: every time the live ``/account`` endpoint
is served we append the observed ``total_assets`` (with a UTC timestamp) to a
small append-only JSON file. No values are ever fabricated — the chart simply
grows as the owner uses the app.

To keep the file bounded and the chart readable we coalesce points within the
same UTC hour (the latest observation in an hour wins) and cap the retained
history to a fixed number of most-recent points.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass
from typing import List


def _default_path() -> str:
    return os.environ.get(
        "TRADEWIZZ_MOOMOO_EQUITY_PATH",
        os.path.join(
            os.environ.get("TRADEWIZZ_DATA_DIR", "data"),
            "moomoo_equity.json",
        ),
    )


# Keep at most this many points (hourly granularity -> ~83 days).
_MAX_POINTS = 2000
# Two observations within the same hour bucket collapse to one.
_BUCKET_SECONDS = 3600


@dataclass
class EquityPoint:
    ts: int        # epoch seconds (UTC)
    equity: float  # total account assets in USD


class EquityTracker:
    """Thread-safe, append-only equity history backed by a JSON file."""

    def __init__(self, path: str | None = None) -> None:
        self._path = path or _default_path()
        self._lock = threading.Lock()

    # -- io ---------------------------------------------------------------
    def _load(self) -> List[EquityPoint]:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except (FileNotFoundError, ValueError, OSError):
            return []
        out: List[EquityPoint] = []
        for item in raw if isinstance(raw, list) else []:
            try:
                out.append(
                    EquityPoint(ts=int(item["ts"]),
                                equity=float(item["equity"]))
                )
            except (KeyError, TypeError, ValueError):
                continue
        out.sort(key=lambda p: p.ts)
        return out

    def _save(self, points: List[EquityPoint]) -> None:
        directory = os.path.dirname(self._path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = f"{self._path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(
                [{"ts": p.ts, "equity": round(p.equity, 2)} for p in points],
                fh,
            )
        os.replace(tmp, self._path)

    # -- api --------------------------------------------------------------
    def record(self, equity: float, ts: int | None = None) -> None:
        """Append a real equity observation, coalescing within the hour."""
        if equity is None or equity <= 0:
            return
        now = int(ts if ts is not None else time.time())
        with self._lock:
            points = self._load()
            bucket = now - (now % _BUCKET_SECONDS)
            if points and (points[-1].ts - (points[-1].ts % _BUCKET_SECONDS)) \
                    == bucket:
                # Same hour bucket: replace with the latest observation.
                points[-1] = EquityPoint(ts=now, equity=float(equity))
            else:
                points.append(EquityPoint(ts=now, equity=float(equity)))
            if len(points) > _MAX_POINTS:
                points = points[-_MAX_POINTS:]
            self._save(points)

    def history(self) -> List[EquityPoint]:
        with self._lock:
            return self._load()
