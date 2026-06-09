"""SQLite persistence for in-app notifications.

One table: notifications (user_id, notification_type, title, body, symbol,
market, created_at, read). A dedup_key prevents the same condition from being
re-notified repeatedly on every refresh.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Protocol

from .models import Notification


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_db_path() -> str:
    env = os.environ.get("TRADEWIZZ_NOTIFICATIONS_DB_PATH")
    if env:
        return env
    base = os.environ.get("TRADEWIZZ_DB_PATH")
    if base:
        return str(Path(base).with_name("notifications.db"))
    return str(
        Path(__file__).resolve().parent.parent.parent
        / "data" / "notifications.db"
    )


class NotificationStore(Protocol):
    def add(self, n: Notification, dedup_key: str) -> Optional[Notification]: ...
    def list_for(self, user_id: int, limit: int = 100) -> List[Notification]: ...
    def unread_count(self, user_id: int) -> int: ...
    def mark_read(
        self, user_id: int, ids: Optional[List[int]] = None
    ) -> int: ...
    def clear_user(self, user_id: int) -> None: ...


def _row_to_notification(row: sqlite3.Row) -> Notification:
    return Notification(
        id=row["id"],
        user_id=row["user_id"],
        notification_type=row["notification_type"],
        title=row["title"],
        body=row["body"],
        symbol=row["symbol"],
        market=row["market"],
        created_at=row["created_at"],
        read=bool(row["read"]),
    )


class SqliteNotificationStore:
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
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS notifications (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id           INTEGER NOT NULL,
                    notification_type TEXT NOT NULL,
                    title             TEXT NOT NULL DEFAULT '',
                    body              TEXT NOT NULL DEFAULT '',
                    symbol            TEXT,
                    market            TEXT,
                    dedup_key         TEXT NOT NULL,
                    created_at        TEXT NOT NULL,
                    read              INTEGER NOT NULL DEFAULT 0
                );
                CREATE UNIQUE INDEX IF NOT EXISTS idx_notif_dedup
                    ON notifications (user_id, dedup_key);
                CREATE INDEX IF NOT EXISTS idx_notif_user
                    ON notifications (user_id, read);
                """
            )
            conn.commit()

    def add(self, n: Notification, dedup_key: str) -> Optional[Notification]:
        """Insert a notification; returns None if the dedup_key already exists."""
        with self._lock:
            conn = self._conn()
            try:
                cur = conn.execute(
                    """INSERT INTO notifications
                       (user_id, notification_type, title, body, symbol,
                        market, dedup_key, created_at, read)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)""",
                    (
                        n.user_id, n.notification_type, n.title, n.body,
                        n.symbol, n.market, dedup_key,
                        n.created_at or _now_iso(),
                    ),
                )
                conn.commit()
            except sqlite3.IntegrityError:
                return None
            n.id = int(cur.lastrowid)
            n.read = False
        return n

    def list_for(self, user_id: int, limit: int = 100) -> List[Notification]:
        with self._lock:
            rows = self._conn().execute(
                """SELECT * FROM notifications WHERE user_id = ?
                   ORDER BY id DESC LIMIT ?""",
                (user_id, limit),
            ).fetchall()
        return [_row_to_notification(r) for r in rows]

    def unread_count(self, user_id: int) -> int:
        with self._lock:
            row = self._conn().execute(
                "SELECT COUNT(*) AS c FROM notifications "
                "WHERE user_id = ? AND read = 0",
                (user_id,),
            ).fetchone()
        return int(row["c"]) if row else 0

    def mark_read(
        self, user_id: int, ids: Optional[List[int]] = None
    ) -> int:
        with self._lock:
            conn = self._conn()
            if ids:
                placeholders = ",".join("?" for _ in ids)
                cur = conn.execute(
                    f"""UPDATE notifications SET read = 1
                        WHERE user_id = ? AND read = 0
                          AND id IN ({placeholders})""",
                    (user_id, *ids),
                )
            else:
                cur = conn.execute(
                    "UPDATE notifications SET read = 1 "
                    "WHERE user_id = ? AND read = 0",
                    (user_id,),
                )
            conn.commit()
            return cur.rowcount or 0

    def clear_user(self, user_id: int) -> None:
        with self._lock:
            conn = self._conn()
            conn.execute(
                "DELETE FROM notifications WHERE user_id = ?", (user_id,)
            )
            conn.commit()
