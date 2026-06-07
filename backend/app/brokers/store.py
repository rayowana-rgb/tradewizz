"""Persistence for per-user broker connections (SQLite + in-memory for tests)."""

from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Protocol

from .models import BrokerType


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class ConnectionRecord:
    id: int
    user_id: int
    broker_type: str
    display_name: str
    is_active: bool
    created_at: str


class ConnectionStore(Protocol):
    def list_for_user(self, user_id: int) -> List[ConnectionRecord]: ...

    def get(self, conn_id: int) -> Optional[ConnectionRecord]: ...

    def create(
        self, user_id: int, broker_type: BrokerType, display_name: str
    ) -> ConnectionRecord: ...

    def delete(self, conn_id: int, user_id: int) -> bool: ...

    def count_active(self, user_id: int) -> int: ...

    def exists_active(self, user_id: int, broker_type: BrokerType) -> bool: ...


class SqliteConnectionStore:
    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._lock, self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS broker_connections (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL,
                    broker_type TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL
                )
                """
            )

    def list_for_user(self, user_id: int) -> List[ConnectionRecord]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM broker_connections WHERE user_id = ? "
                "ORDER BY id",
                (user_id,),
            ).fetchall()
        return [self._rec(r) for r in rows]

    def get(self, conn_id: int) -> Optional[ConnectionRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM broker_connections WHERE id = ?", (conn_id,)
            ).fetchone()
        return self._rec(row) if row else None

    def create(self, user_id, broker_type, display_name) -> ConnectionRecord:
        now = _now_iso()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO broker_connections (user_id, broker_type, "
                "display_name, is_active, created_at) VALUES (?, ?, ?, 1, ?)",
                (user_id, broker_type.value, display_name, now),
            )
            cid = cur.lastrowid
        return ConnectionRecord(
            cid, user_id, broker_type.value, display_name, True, now
        )

    def delete(self, conn_id: int, user_id: int) -> bool:
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "DELETE FROM broker_connections WHERE id = ? AND user_id = ?",
                (conn_id, user_id),
            )
            return cur.rowcount > 0

    def count_active(self, user_id: int) -> int:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS n FROM broker_connections WHERE "
                "user_id = ? AND is_active = 1",
                (user_id,),
            ).fetchone()
        return int(row["n"]) if row else 0

    def exists_active(self, user_id, broker_type) -> bool:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT 1 FROM broker_connections WHERE user_id = ? AND "
                "broker_type = ? AND is_active = 1 LIMIT 1",
                (user_id, broker_type.value),
            ).fetchone()
        return row is not None

    @staticmethod
    def _rec(row) -> ConnectionRecord:
        return ConnectionRecord(
            id=row["id"],
            user_id=row["user_id"],
            broker_type=row["broker_type"],
            display_name=row["display_name"],
            is_active=bool(row["is_active"]),
            created_at=row["created_at"],
        )


class InMemoryConnectionStore:
    def __init__(self):
        self._rows: dict[int, ConnectionRecord] = {}
        self._next_id = 1

    def list_for_user(self, user_id: int) -> List[ConnectionRecord]:
        return [r for r in self._rows.values() if r.user_id == user_id]

    def get(self, conn_id: int) -> Optional[ConnectionRecord]:
        return self._rows.get(conn_id)

    def create(self, user_id, broker_type, display_name) -> ConnectionRecord:
        rec = ConnectionRecord(
            self._next_id, user_id, broker_type.value, display_name, True,
            _now_iso(),
        )
        self._rows[rec.id] = rec
        self._next_id += 1
        return rec

    def delete(self, conn_id: int, user_id: int) -> bool:
        rec = self._rows.get(conn_id)
        if rec is None or rec.user_id != user_id:
            return False
        del self._rows[conn_id]
        return True

    def count_active(self, user_id: int) -> int:
        return sum(
            1 for r in self._rows.values()
            if r.user_id == user_id and r.is_active
        )

    def exists_active(self, user_id, broker_type) -> bool:
        return any(
            r.user_id == user_id and r.broker_type == broker_type.value
            and r.is_active
            for r in self._rows.values()
        )
