"""Persistence for portfolio snapshots (equity curve)."""

from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Protocol


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class SnapshotRecord:
    id: int
    user_id: int
    timestamp: str
    total_equity: float
    cash: float
    market_value: float
    floating_pnl: float
    realized_pnl: float


class SnapshotStore(Protocol):
    def create(
        self,
        user_id: int,
        total_equity: float,
        cash: float,
        market_value: float,
        floating_pnl: float,
        realized_pnl: float,
        timestamp: Optional[str] = None,
    ) -> SnapshotRecord: ...

    def list_for_user(
        self, user_id: int, limit: int = 90
    ) -> List[SnapshotRecord]: ...

    def latest_before(
        self, user_id: int, before_iso: str
    ) -> Optional[SnapshotRecord]: ...


class SqliteSnapshotStore:
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
                CREATE TABLE IF NOT EXISTS portfolio_snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL,
                    timestamp TEXT NOT NULL,
                    total_equity REAL NOT NULL,
                    cash REAL NOT NULL,
                    market_value REAL NOT NULL,
                    floating_pnl REAL NOT NULL,
                    realized_pnl REAL NOT NULL
                )
                """
            )

    def create(self, user_id, total_equity, cash, market_value, floating_pnl,
               realized_pnl, timestamp=None) -> SnapshotRecord:
        ts = timestamp or _now_iso()
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO portfolio_snapshots (user_id, timestamp, "
                "total_equity, cash, market_value, floating_pnl, realized_pnl) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (user_id, ts, total_equity, cash, market_value, floating_pnl,
                 realized_pnl),
            )
            sid = cur.lastrowid
        return SnapshotRecord(sid, user_id, ts, total_equity, cash,
                              market_value, floating_pnl, realized_pnl)

    def list_for_user(self, user_id, limit=90) -> List[SnapshotRecord]:
        with self._lock, self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM portfolio_snapshots WHERE user_id = ? "
                "ORDER BY timestamp ASC, id ASC LIMIT ?",
                (user_id, limit),
            ).fetchall()
        return [self._rec(r) for r in rows]

    def latest_before(self, user_id, before_iso) -> Optional[SnapshotRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM portfolio_snapshots WHERE user_id = ? AND "
                "timestamp < ? ORDER BY timestamp DESC, id DESC LIMIT 1",
                (user_id, before_iso),
            ).fetchone()
        return self._rec(row) if row else None

    @staticmethod
    def _rec(row) -> SnapshotRecord:
        return SnapshotRecord(
            id=row["id"], user_id=row["user_id"], timestamp=row["timestamp"],
            total_equity=row["total_equity"], cash=row["cash"],
            market_value=row["market_value"], floating_pnl=row["floating_pnl"],
            realized_pnl=row["realized_pnl"],
        )


class InMemorySnapshotStore:
    def __init__(self):
        self._rows: List[SnapshotRecord] = []
        self._next_id = 1

    def create(self, user_id, total_equity, cash, market_value, floating_pnl,
               realized_pnl, timestamp=None) -> SnapshotRecord:
        rec = SnapshotRecord(
            self._next_id, user_id, timestamp or _now_iso(), total_equity,
            cash, market_value, floating_pnl, realized_pnl,
        )
        self._rows.append(rec)
        self._next_id += 1
        return rec

    def list_for_user(self, user_id, limit=90) -> List[SnapshotRecord]:
        rows = [r for r in self._rows if r.user_id == user_id]
        rows.sort(key=lambda r: (r.timestamp, r.id))
        return rows[-limit:]

    def latest_before(self, user_id, before_iso) -> Optional[SnapshotRecord]:
        candidates = [
            r for r in self._rows
            if r.user_id == user_id and r.timestamp < before_iso
        ]
        if not candidates:
            return None
        return max(candidates, key=lambda r: (r.timestamp, r.id))
