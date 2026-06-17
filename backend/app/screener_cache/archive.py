"""Daily OHLCV archive with a rolling retention window (default 30 days).

The live ``OhlcvCache`` keeps exactly ONE entry per (ticker, period, interval)
and overwrites it on a new trading day — it always reflects the latest data the
screener should compute from. That means yesterday's frame is gone once today
is warmed.

This archive is the durable, day-keyed companion the user asked for: when the
daily warmer fetches a symbol after market close, it also writes that symbol's
OHLCV frame into a per-(market, trading_date) folder. Archived days are kept for
``RETENTION_DAYS`` (default 30) and older days are purged. It is purely
additive — it never touches the live cache or any scoring/engine behaviour.

Layout::

    <archive_dir>/<MARKET>/<YYYY-MM-DD>/<TICKER>.csv.gz

CSV(+gzip) keeps it dependency-light (no parquet engine required), matching the
live cache's storage choice. Writes are best-effort: an archive failure must
never break the warm loop.
"""

from __future__ import annotations

import gzip
import logging
import os
import shutil
import threading
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import List, Optional

import pandas as pd

logger = logging.getLogger("tradewiz.archive")

DEFAULT_RETENTION_DAYS = 30


def _default_archive_dir() -> Path:
    env = os.environ.get("TRADEWIZZ_ARCHIVE_DIR")
    if env:
        return Path(env)
    return Path(__file__).resolve().parent.parent.parent / ".cache" / "ohlcv_archive"


def _retention_days() -> int:
    raw = os.environ.get("TRADEWIZZ_ARCHIVE_RETENTION_DAYS")
    if raw is None:
        return DEFAULT_RETENTION_DAYS
    try:
        val = int(raw)
        return val if val > 0 else DEFAULT_RETENTION_DAYS
    except (TypeError, ValueError):
        return DEFAULT_RETENTION_DAYS


def _safe_name(name: str) -> str:
    """Filesystem-safe ticker/market token."""
    return "".join(c if (c.isalnum() or c in "._-") else "_" for c in name)


class DailyOhlcvArchive:
    """Day-keyed OHLCV archive with rolling retention.

    Thread-safe enough for the warmer's single writer thread; the retention
    purge is guarded so a concurrent debug call can't race directory removal.
    """

    def __init__(
        self,
        archive_dir: Optional[Path | str] = None,
        retention_days: Optional[int] = None,
    ) -> None:
        self._dir = Path(archive_dir) if archive_dir else _default_archive_dir()
        self._retention = (
            retention_days if retention_days is not None else _retention_days()
        )
        self._lock = threading.Lock()
        self._dir.mkdir(parents=True, exist_ok=True)

    @property
    def retention_days(self) -> int:
        return self._retention

    @property
    def root(self) -> Path:
        return self._dir

    def _day_dir(self, market_code: str, trading_date: str) -> Path:
        return self._dir / _safe_name(market_code) / _safe_name(trading_date)

    # -- write -------------------------------------------------------------
    def store(
        self,
        market_code: str,
        trading_date: str,
        ticker: str,
        df: pd.DataFrame,
    ) -> bool:
        """Archive one symbol's OHLCV frame for a trading date. Best-effort.

        Returns True on a successful write, False otherwise (never raises).
        """
        if df is None or getattr(df, "empty", True):
            return False
        try:
            day_dir = self._day_dir(market_code, trading_date)
            day_dir.mkdir(parents=True, exist_ok=True)
            path = day_dir / f"{_safe_name(ticker)}.csv.gz"
            # Atomic-ish: write to a temp then replace.
            tmp = path.with_suffix(path.suffix + ".tmp")
            with gzip.open(tmp, "wt", newline="") as fh:
                df.to_csv(fh)
            os.replace(tmp, path)
            return True
        except Exception as exc:  # noqa: BLE001 — archiving must never break warm
            logger.debug("archive store failed %s/%s/%s: %s",
                         market_code, trading_date, ticker, exc)
            return False

    # -- read --------------------------------------------------------------
    def load(
        self, market_code: str, trading_date: str, ticker: str
    ) -> Optional[pd.DataFrame]:
        """Load one archived symbol frame, or None if absent/unreadable."""
        path = self._day_dir(market_code, trading_date) / f"{_safe_name(ticker)}.csv.gz"
        if not path.exists():
            return None
        try:
            with gzip.open(path, "rt") as fh:
                return pd.read_csv(fh, index_col=0)
        except Exception as exc:  # noqa: BLE001
            logger.debug("archive load failed %s: %s", path, exc)
            return None

    # -- retention ---------------------------------------------------------
    def _parse_day(self, name: str) -> Optional[date]:
        try:
            return datetime.strptime(name, "%Y-%m-%d").date()
        except (TypeError, ValueError):
            return None

    def purge_old(self, *, today: Optional[date] = None) -> int:
        """Remove archived day folders older than the retention window.

        Returns the number of day-folders removed. Keeps days where
        ``today - day < retention_days`` (so retention_days=30 keeps ~the last
        30 trading-date folders).
        """
        cutoff = (today or date.today()) - timedelta(days=self._retention)
        removed = 0
        with self._lock:
            if not self._dir.exists():
                return 0
            for market_dir in self._dir.iterdir():
                if not market_dir.is_dir():
                    continue
                for day_dir in market_dir.iterdir():
                    if not day_dir.is_dir():
                        continue
                    d = self._parse_day(day_dir.name)
                    if d is None:
                        continue
                    if d <= cutoff:
                        try:
                            shutil.rmtree(day_dir)
                            removed += 1
                        except Exception as exc:  # noqa: BLE001
                            logger.debug("archive purge failed %s: %s", day_dir, exc)
        if removed:
            logger.info("archive: purged %d day-folder(s) older than %s",
                        removed, cutoff.isoformat())
        return removed

    # -- introspection -----------------------------------------------------
    def stored_days(self, market_code: str) -> List[str]:
        """Sorted list of archived trading dates for a market."""
        market_dir = self._dir / _safe_name(market_code)
        if not market_dir.exists():
            return []
        days = [
            p.name for p in market_dir.iterdir()
            if p.is_dir() and self._parse_day(p.name) is not None
        ]
        return sorted(days)

    def summary(self) -> dict:
        """Per-market archived day counts + retention, for diagnostics."""
        out: dict = {}
        if self._dir.exists():
            for market_dir in sorted(self._dir.iterdir()):
                if not market_dir.is_dir():
                    continue
                days = self.stored_days(market_dir.name)
                if days:
                    out[market_dir.name] = {
                        "days": len(days),
                        "oldest": days[0],
                        "newest": days[-1],
                    }
        return {"retention_days": self._retention, "markets": out}
