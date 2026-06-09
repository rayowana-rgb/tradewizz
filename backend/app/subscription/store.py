"""SQLite persistence for subscriptions + usage analytics (per user).

Tables:
  * subscriptions      - one row per user (tier, dates, active).
  * usage_events       - append-only analytics log (Phase 9): every analysis
                         request, radar view, watchlist op, portfolio view.
  * usage_daily        - per (user, day, metric) counter, used for hard limits
                         (e.g. FREE = 5 analyses/day) without scanning the log.

No broker tables. No payment data is stored (billing is external/placeholder).
"""

from __future__ import annotations

import os
import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Protocol


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _today_str() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _default_db_path() -> str:
    env = os.environ.get("TRADEWIZZ_SUB_DB_PATH")
    if env:
        return env
    base = os.environ.get("TRADEWIZZ_DB_PATH")
    if base:
        return str(Path(base).with_name("subscription.db"))
    return str(
        Path(__file__).resolve().parent.parent.parent
        / "data"
        / "subscription.db"
    )


@dataclass
class SubscriptionRow:
    user_id: int
    tier: str
    started_at: str
    expires_at: Optional[str]
    active: bool
    created_at: str
    updated_at: str


class SubscriptionStore(Protocol):
    def get(self, user_id: int) -> Optional[SubscriptionRow]: ...
    def upsert(self, row: SubscriptionRow) -> SubscriptionRow: ...
    def record_event(
        self, user_id: int, metric: str, count: int = 1, meta: str = ""
    ) -> None: ...
    def usage_today(self, user_id: int, metric: str) -> int: ...
    def usage_summary(self, user_id: int) -> Dict[str, int]: ...


class SqliteSubscriptionStore:
    def __init__(self, db_path: Optional[str] = None):
        self._path = db_path or _default_db_path()
        if self._path != ":memory:":
            Path(self._path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._shared = (
            sqlite3.connect(self._path, check_same_thread=False)
            if self._path == ":memory:"
            else None
        )
        self._init_schema()

    def _conn(self) -> sqlite3.Connection:
        if self._shared is not None:
            self._shared.row_factory = sqlite3.Row
            return self._shared
        conn = sqlite3.connect(self._path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_schema(self) -> None:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS subscriptions (
                    user_id    INTEGER PRIMARY KEY,
                    tier       TEXT NOT NULL DEFAULT 'FREE',
                    started_at TEXT NOT NULL,
                    expires_at TEXT,
                    active     INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS usage_events (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id    INTEGER NOT NULL,
                    metric     TEXT NOT NULL,
                    count      INTEGER NOT NULL DEFAULT 1,
                    meta       TEXT NOT NULL DEFAULT '',
                    day        TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS usage_daily (
                    user_id INTEGER NOT NULL,
                    day     TEXT NOT NULL,
                    metric  TEXT NOT NULL,
                    count   INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (user_id, day, metric)
                );
                CREATE INDEX IF NOT EXISTS idx_usage_events_user
                    ON usage_events (user_id, metric, day);
                """
            )
            conn.commit()

    # -- subscriptions ---------------------------------------------------
    def get(self, user_id: int) -> Optional[SubscriptionRow]:
        with self._lock:
            row = self._conn().execute(
                "SELECT * FROM subscriptions WHERE user_id = ?", (user_id,)
            ).fetchone()
        if row is None:
            return None
        return SubscriptionRow(
            user_id=row["user_id"],
            tier=row["tier"],
            started_at=row["started_at"],
            expires_at=row["expires_at"],
            active=bool(row["active"]),
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )

    def upsert(self, row: SubscriptionRow) -> SubscriptionRow:
        with self._lock:
            conn = self._conn()
            conn.execute(
                """
                INSERT INTO subscriptions
                    (user_id, tier, started_at, expires_at, active,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    tier=excluded.tier,
                    started_at=excluded.started_at,
                    expires_at=excluded.expires_at,
                    active=excluded.active,
                    updated_at=excluded.updated_at
                """,
                (
                    row.user_id,
                    row.tier,
                    row.started_at,
                    row.expires_at,
                    1 if row.active else 0,
                    row.created_at,
                    row.updated_at,
                ),
            )
            conn.commit()
        return row

    # -- analytics / usage ----------------------------------------------
    def record_event(
        self, user_id: int, metric: str, count: int = 1, meta: str = ""
    ) -> None:
        day = _today_str()
        now = _now_iso()
        with self._lock:
            conn = self._conn()
            conn.execute(
                """INSERT INTO usage_events
                   (user_id, metric, count, meta, day, created_at)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (user_id, metric, count, meta, day, now),
            )
            conn.execute(
                """INSERT INTO usage_daily (user_id, day, metric, count)
                   VALUES (?, ?, ?, ?)
                   ON CONFLICT(user_id, day, metric) DO UPDATE SET
                       count = count + excluded.count""",
                (user_id, day, metric, count),
            )
            conn.commit()

    def usage_today(self, user_id: int, metric: str) -> int:
        day = _today_str()
        with self._lock:
            row = self._conn().execute(
                """SELECT count FROM usage_daily
                   WHERE user_id = ? AND day = ? AND metric = ?""",
                (user_id, day, metric),
            ).fetchone()
        return int(row["count"]) if row else 0

    def usage_summary(self, user_id: int) -> Dict[str, int]:
        """Lifetime totals per metric (for monetization analytics)."""
        with self._lock:
            rows = self._conn().execute(
                """SELECT metric, SUM(count) AS total FROM usage_events
                   WHERE user_id = ? GROUP BY metric""",
                (user_id,),
            ).fetchall()
        return {r["metric"]: int(r["total"]) for r in rows}
