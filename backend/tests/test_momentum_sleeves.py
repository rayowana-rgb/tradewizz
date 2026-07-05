"""Unit tests for per-sleeve tracking (momentum-vs-passive A/B)."""
from __future__ import annotations

import os
import tempfile

from app.momentum.sleeves import (
    SleeveTracker,
    SleevePoint,
    TARGET_ALLOCATION,
    sleeve_metrics,
    _max_drawdown,
    _series_return,
)


def test_target_allocation_sums_to_one():
    assert abs(sum(TARGET_ALLOCATION.values()) - 1.0) < 1e-9
    assert TARGET_ALLOCATION == {"momentum": 0.50, "passive": 0.30, "cash": 0.20}


def test_series_return_and_drawdown():
    # +20% overall, worst dip 100 -> 80 = -20%.
    vals = [100.0, 120.0, 80.0, 110.0]
    assert abs(_series_return(vals) - 0.10) < 1e-9
    assert abs(_max_drawdown(vals) - (-1 / 3)) < 1e-9  # 120 -> 80


def test_metrics_need_two_points():
    assert _series_return([100.0]) is None
    assert _max_drawdown([100.0]) is None
    assert _series_return([]) is None


def test_tracker_records_and_coalesces_within_hour(tmp_path):
    p = tmp_path / "sleeves.json"
    t = SleeveTracker(str(p))
    base = 1_000_000  # arbitrary epoch inside one hour bucket
    t.record(momentum=100.0, passive=50.0, cash=20.0, ts=base)
    t.record(momentum=110.0, passive=55.0, cash=15.0, ts=base + 100)  # same hr
    hist = t.history()
    assert len(hist) == 1  # coalesced
    assert hist[-1].momentum == 110.0
    # New hour -> new point.
    t.record(momentum=120.0, passive=60.0, cash=10.0, ts=base + 3700)
    hist = t.history()
    assert len(hist) == 2
    assert abs(hist[-1].total - 190.0) < 1e-9


def test_sleeve_metrics_shape():
    pts = [
        SleevePoint(ts=0, momentum=100.0, passive=200.0, cash=50.0),
        SleevePoint(ts=3600, momentum=110.0, passive=190.0, cash=50.0),
    ]
    m = sleeve_metrics(pts)
    assert set(m) == {"momentum", "passive", "total"}
    assert abs(m["momentum"]["return_pct"] - 0.10) < 1e-9
    assert m["momentum"]["points"] == 2
