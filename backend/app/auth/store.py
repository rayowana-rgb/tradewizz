"""User persistence (SQLite) with an injectable interface for tests."""

from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Protocol


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class UserRecord:
    id: int
    email: str
    password_hash: str
    created_at: str
    updated_at: str


class UserStore(Protocol):
    def get_by_email(self, email: str) -> Optional[UserRecord]: ...

    def get_by_id(self, user_id: int) -> Optional[UserRecord]: ...

    def create(self, email: str, password_hash: str) -> UserRecord: ...


class SqliteUserStore:
    """SQLite-backed user store. Thread-safe via a lock + per-call connection."""

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
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    password_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )

    def get_by_email(self, email: str) -> Optional[UserRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE email = ? COLLATE NOCASE",
                (email.strip().lower(),),
            ).fetchone()
        return self._to_record(row)

    def get_by_id(self, user_id: int) -> Optional[UserRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE id = ?", (user_id,)
            ).fetchone()
        return self._to_record(row)

    def create(self, email: str, password_hash: str) -> UserRecord:
        now = _now_iso()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO users (email, password_hash, created_at, "
                "updated_at) VALUES (?, ?, ?, ?)",
                (email.strip().lower(), password_hash, now, now),
            )
            uid = cur.lastrowid
        return UserRecord(uid, email.strip().lower(), password_hash, now, now)

    @staticmethod
    def _to_record(row) -> Optional[UserRecord]:
        if row is None:
            return None
        return UserRecord(
            id=row["id"],
            email=row["email"],
            password_hash=row["password_hash"],
            created_at=row["created_at"],
            updated_at=row["updated_at"],
        )


class InMemoryUserStore:
    """In-memory user store for tests (no disk)."""

    def __init__(self):
        self._by_id: dict[int, UserRecord] = {}
        self._by_email: dict[str, UserRecord] = {}
        self._next_id = 1

    def get_by_email(self, email: str) -> Optional[UserRecord]:
        return self._by_email.get(email.strip().lower())

    def get_by_id(self, user_id: int) -> Optional[UserRecord]:
        return self._by_id.get(user_id)

    def create(self, email: str, password_hash: str) -> UserRecord:
        now = _now_iso()
        rec = UserRecord(self._next_id, email.strip().lower(), password_hash,
                         now, now)
        self._by_id[rec.id] = rec
        self._by_email[rec.email] = rec
        self._next_id += 1
        return rec
