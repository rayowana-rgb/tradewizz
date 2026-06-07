"""User persistence (SQLite) with an injectable interface for tests.

Supports multiple auth providers (EMAIL / GOOGLE / APPLE). EMAIL users keep a
bcrypt ``password_hash``; social users (GOOGLE/APPLE) store no password (empty
hash) and instead carry a ``provider_user_id`` (the verified subject from the
identity provider).
"""

from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Protocol

# Provider identifiers. Kept as plain strings so the store stays dependency-free
# and forward compatible with new providers.
PROVIDER_EMAIL = "EMAIL"
PROVIDER_GOOGLE = "GOOGLE"
PROVIDER_APPLE = "APPLE"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class UserRecord:
    id: int
    email: str
    password_hash: str
    created_at: str
    updated_at: str
    # Auth provider this account was created with.
    provider: str = PROVIDER_EMAIL
    # Stable subject id from the social provider (empty for EMAIL users).
    provider_user_id: Optional[str] = None


class UserStore(Protocol):
    def get_by_email(self, email: str) -> Optional[UserRecord]: ...

    def get_by_id(self, user_id: int) -> Optional[UserRecord]: ...

    def get_by_provider(
        self, provider: str, provider_user_id: str
    ) -> Optional[UserRecord]: ...

    def create(
        self,
        email: str,
        password_hash: str,
        *,
        provider: str = PROVIDER_EMAIL,
        provider_user_id: Optional[str] = None,
    ) -> UserRecord: ...


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
                    password_hash TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    provider TEXT NOT NULL DEFAULT 'EMAIL',
                    provider_user_id TEXT
                )
                """
            )
            # Additive migration: add provider columns to pre-existing tables.
            self._ensure_column(conn, "provider", "TEXT NOT NULL DEFAULT 'EMAIL'")
            self._ensure_column(conn, "provider_user_id", "TEXT")
            conn.execute(
                "CREATE INDEX IF NOT EXISTS ix_users_provider "
                "ON users (provider, provider_user_id)"
            )

    @staticmethod
    def _ensure_column(conn: sqlite3.Connection, name: str, decl: str) -> None:
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(users)")}
        if name not in cols:
            conn.execute(f"ALTER TABLE users ADD COLUMN {name} {decl}")

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

    def get_by_provider(
        self, provider: str, provider_user_id: str
    ) -> Optional[UserRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM users WHERE provider = ? AND "
                "provider_user_id = ?",
                (provider, provider_user_id),
            ).fetchone()
        return self._to_record(row)

    def create(
        self,
        email: str,
        password_hash: str,
        *,
        provider: str = PROVIDER_EMAIL,
        provider_user_id: Optional[str] = None,
    ) -> UserRecord:
        now = _now_iso()
        email = email.strip().lower()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO users (email, password_hash, created_at, "
                "updated_at, provider, provider_user_id) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (email, password_hash, now, now, provider, provider_user_id),
            )
            uid = cur.lastrowid
        return UserRecord(
            id=uid,
            email=email,
            password_hash=password_hash,
            created_at=now,
            updated_at=now,
            provider=provider,
            provider_user_id=provider_user_id,
        )

    @staticmethod
    def _to_record(row) -> Optional[UserRecord]:
        if row is None:
            return None
        keys = row.keys()
        return UserRecord(
            id=row["id"],
            email=row["email"],
            password_hash=row["password_hash"] or "",
            created_at=row["created_at"],
            updated_at=row["updated_at"],
            provider=(row["provider"] if "provider" in keys else PROVIDER_EMAIL)
            or PROVIDER_EMAIL,
            provider_user_id=(
                row["provider_user_id"] if "provider_user_id" in keys else None
            ),
        )


class InMemoryUserStore:
    """In-memory user store for tests (no disk)."""

    def __init__(self):
        self._by_id: dict[int, UserRecord] = {}
        self._by_email: dict[str, UserRecord] = {}
        self._by_provider: dict[tuple[str, str], UserRecord] = {}
        self._next_id = 1

    def get_by_email(self, email: str) -> Optional[UserRecord]:
        return self._by_email.get(email.strip().lower())

    def get_by_id(self, user_id: int) -> Optional[UserRecord]:
        return self._by_id.get(user_id)

    def get_by_provider(
        self, provider: str, provider_user_id: str
    ) -> Optional[UserRecord]:
        return self._by_provider.get((provider, provider_user_id))

    def create(
        self,
        email: str,
        password_hash: str,
        *,
        provider: str = PROVIDER_EMAIL,
        provider_user_id: Optional[str] = None,
    ) -> UserRecord:
        now = _now_iso()
        rec = UserRecord(
            id=self._next_id,
            email=email.strip().lower(),
            password_hash=password_hash,
            created_at=now,
            updated_at=now,
            provider=provider,
            provider_user_id=provider_user_id,
        )
        self._by_id[rec.id] = rec
        self._by_email[rec.email] = rec
        if provider_user_id is not None:
            self._by_provider[(provider, provider_user_id)] = rec
        self._next_id += 1
        return rec
