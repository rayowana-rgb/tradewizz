"""Per-sleeve portfolio tracking for the momentum-vs-passive A/B test.

The owner runs two strategies inside the ONE live Moomoo account and wants to
compare them honestly on profit AND resilience (drawdown). To do that we must
split the single account into named "sleeves" and record each sleeve's value
over time separately -- the combined account equity curve cannot tell you which
strategy is winning.

Sleeve definition (kept deliberately simple and evidence-based):

- ``momentum`` -- positions the momentum strategy actually bought, i.e. symbols
  present in the momentum ledger (``tw:momentum``), intersected with the live
  positions. This is the same join the /holdings endpoint uses.
- ``passive``  -- every other live position (the broad, near-equal-weight book).
- ``cash``     -- the account's free cash (the dry-powder buffer).

Target allocation (the owner's decision, 2026-07-06): 50% momentum / 30%
passive / 20% cash buffer.

Like ``EquityTracker`` this records ONLY real observations. Every time the
sleeve snapshot is served we append a genuine data point; no history is ever
fabricated. Metrics (return, max drawdown) are computed from that real series.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional

# Owner's target allocation (fractions of total account value).
TARGET_ALLOCATION: Dict[str, float] = {
    "momentum": 0.50,
    "passive": 0.30,
    "cash": 0.20,
}

_MAX_POINTS = 2000
_BUCKET_SECONDS = 3600


def _default_path() -> str:
    return os.environ.get(
        "TRADEWIZZ_MOOMOO_SLEEVE_PATH",
        os.path.join(
            os.environ.get("TRADEWIZZ_DATA_DIR", "data"),
            "moomoo_sleeves.json",
        ),
    )


@dataclass
class SleevePoint:
    ts: int             # epoch seconds (UTC)
    momentum: float     # momentum sleeve market value (USD)
    passive: float      # passive sleeve market value (USD)
    cash: float         # free cash (USD, can be negative if margined)

    @property
    def total(self) -> float:
        return self.momentum + self.passive + self.cash


class SleeveTracker:
    """Thread-safe, append-only per-sleeve value history (JSON backed)."""

    def __init__(self, path: Optional[str] = None) -> None:
        self._path = path or _default_path()
        self._lock = threading.Lock()

    # -- io ---------------------------------------------------------------
    def _load(self) -> List[SleevePoint]:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except (FileNotFoundError, ValueError, OSError):
            return []
        out: List[SleevePoint] = []
        for item in raw if isinstance(raw, list) else []:
            try:
                out.append(
                    SleevePoint(
                        ts=int(item["ts"]),
                        momentum=float(item["momentum"]),
                        passive=float(item["passive"]),
                        cash=float(item["cash"]),
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue
        out.sort(key=lambda p: p.ts)
        return out

    def _save(self, points: List[SleevePoint]) -> None:
        directory = os.path.dirname(self._path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        tmp = f"{self._path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(
                [
                    {
                        "ts": p.ts,
                        "momentum": round(p.momentum, 2),
                        "passive": round(p.passive, 2),
                        "cash": round(p.cash, 2),
                    }
                    for p in points
                ],
                fh,
            )
        os.replace(tmp, self._path)

    # -- api --------------------------------------------------------------
    def record(
        self,
        momentum: float,
        passive: float,
        cash: float,
        ts: Optional[int] = None,
    ) -> None:
        """Append a real sleeve observation, coalescing within the hour."""
        now = int(ts if ts is not None else time.time())
        with self._lock:
            points = self._load()
            bucket = now - (now % _BUCKET_SECONDS)
            pt = SleevePoint(
                ts=now,
                momentum=float(momentum),
                passive=float(passive),
                cash=float(cash),
            )
            if points and (
                points[-1].ts - (points[-1].ts % _BUCKET_SECONDS)
            ) == bucket:
                points[-1] = pt
            else:
                points.append(pt)
            if len(points) > _MAX_POINTS:
                points = points[-_MAX_POINTS:]
            self._save(points)

    def history(self) -> List[SleevePoint]:
        with self._lock:
            return self._load()


def _series_return(values: List[float]) -> Optional[float]:
    """Total return over a value series (last/first - 1), or None if < 2 pts
    or the first value is non-positive."""
    if len(values) < 2 or values[0] <= 0:
        return None
    return values[-1] / values[0] - 1.0


def _max_drawdown(values: List[float]) -> Optional[float]:
    """Worst peak-to-trough decline over the series as a negative fraction
    (e.g. -0.12 = -12%). None if fewer than 2 points. This is our resilience
    measure -- smaller magnitude = more resilient."""
    if len(values) < 2:
        return None
    peak = values[0]
    worst = 0.0
    for v in values:
        if v > peak:
            peak = v
        if peak > 0:
            dd = v / peak - 1.0
            if dd < worst:
                worst = dd
    return worst


def sleeve_metrics(points: List[SleevePoint]) -> Dict[str, dict]:
    """Compute per-sleeve return and max drawdown from a real value series.

    Returns a dict keyed by sleeve name; each value has ``return_pct`` and
    ``max_drawdown`` (both fractions) which may be None when there is not yet
    enough history to compute them honestly."""
    out: Dict[str, dict] = {}
    for name in ("momentum", "passive", "total"):
        if name == "total":
            series = [p.total for p in points]
        elif name == "momentum":
            series = [p.momentum for p in points]
        else:
            series = [p.passive for p in points]
        out[name] = {
            "return_pct": _series_return(series),
            "max_drawdown": _max_drawdown(series),
            "points": len(series),
        }
    return out
