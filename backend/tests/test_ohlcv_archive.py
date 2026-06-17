"""Tests for the daily OHLCV archive (rolling 30-day retention)."""

from __future__ import annotations

from datetime import date
from zoneinfo import ZoneInfo
from datetime import datetime

import pandas as pd
import pytest

from app.models import Market
from app.screener_cache.archive import DailyOhlcvArchive
from app.screener_cache.warmer import DailyCacheWarmer


def _frame():
    return pd.DataFrame(
        {
            "Open": [10.0, 11.0],
            "High": [11.0, 12.0],
            "Low": [9.5, 10.5],
            "Close": [10.5, 11.5],
            "Volume": [1000, 1200],
        },
        index=pd.to_datetime(["2026-06-16", "2026-06-17"]),
    )


def test_store_and_load_roundtrip(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path, retention_days=30)
    assert arc.store("IDX", "2026-06-17", "BBCA.JK", _frame()) is True
    got = arc.load("IDX", "2026-06-17", "BBCA.JK")
    assert got is not None
    assert list(got["Close"]) == [10.5, 11.5]
    assert (tmp_path / "IDX" / "2026-06-17" / "BBCA.JK.csv.gz").exists()


def test_store_empty_frame_is_skipped(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path)
    assert arc.store("IDX", "2026-06-17", "X", pd.DataFrame()) is False
    assert arc.load("IDX", "2026-06-17", "X") is None


def test_days_are_separate(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path)
    arc.store("US", "2026-06-16", "MSFT", _frame())
    arc.store("US", "2026-06-17", "MSFT", _frame())
    assert arc.stored_days("US") == ["2026-06-16", "2026-06-17"]


def test_purge_keeps_last_30_days(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path, retention_days=30)
    # Old (45 days ago) + recent (5 days ago) relative to a fixed "today".
    today = date(2026, 6, 17)
    arc.store("IDX", "2026-05-03", "A", _frame())  # 45 days ago -> purge
    arc.store("IDX", "2026-06-12", "A", _frame())  # 5 days ago -> keep
    removed = arc.purge_old(today=today)
    assert removed == 1
    assert arc.stored_days("IDX") == ["2026-06-12"]


def test_purge_boundary_exactly_30_days(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path, retention_days=30)
    today = date(2026, 6, 17)
    arc.store("IDX", "2026-05-18", "A", _frame())  # exactly 30 days -> purge (<=cutoff)
    arc.store("IDX", "2026-05-19", "A", _frame())  # 29 days -> keep
    removed = arc.purge_old(today=today)
    assert removed == 1
    assert arc.stored_days("IDX") == ["2026-05-19"]


def test_summary_reports_per_market(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path, retention_days=30)
    arc.store("IDX", "2026-06-16", "A", _frame())
    arc.store("IDX", "2026-06-17", "A", _frame())
    arc.store("US", "2026-06-17", "MSFT", _frame())
    s = arc.summary()
    assert s["retention_days"] == 30
    assert s["markets"]["IDX"] == {"days": 2, "oldest": "2026-06-16", "newest": "2026-06-17"}
    assert s["markets"]["US"]["days"] == 1


def test_warmer_archives_each_warmed_symbol(tmp_path):
    arc = DailyOhlcvArchive(archive_dir=tmp_path, retention_days=30)

    def fetch(symbol, market):
        # Returning a frame lets the warmer archive it.
        return _frame()

    def now_provider(market):
        return datetime(2026, 6, 17, 18, 0, tzinfo=ZoneInfo("Asia/Jakarta"))

    w = DailyCacheWarmer(
        fetch_symbol=fetch,
        symbols_for=lambda mk: ["AAA", "BBB"],
        markets=[Market.IDX],
        fetch_delay_seconds=0.0,
        now_provider=now_provider,
        archive=arc,
    )
    assert w.tick() == ["IDX"]
    # Both symbols archived under the IDX trading date.
    assert arc.load("IDX", "2026-06-17", "AAA") is not None
    assert arc.load("IDX", "2026-06-17", "BBB") is not None
    assert w.last_warm["IDX"]["archived"] == 2
