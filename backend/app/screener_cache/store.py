"""Persistence for market-close screener snapshots.

A snapshot is the full screening payload for one (market, category-key, params)
combination, captured once after a market close. The store keeps the latest
snapshot per cache key and can answer "does today's market-close snapshot exist
for this market?" so the API never re-screens repeatedly.

Two implementations:
  - ``SqliteScreenerSnapshotStore``: durable (production / dev).
  - ``InMemoryScreenerSnapshotStore``: hermetic, for tests.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Protocol


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class ScreenerSnapshotRecord:
    id: int
    market: str
    category: str  # cache-key string (params + category filter); "" if none
    generated_at: str  # ISO-8601 UTC (when this snapshot was produced)
    market_date: str  # YYYY-MM-DD in the market's local timezone
    market_status: str  # "OPEN" or "CLOSED" at capture time (typically CLOSED)
    payload_json: str  # serialized ScreenerResult-ish dict

    def payload(self) -> dict:
        return json.loads(self.payload_json)


class ScreenerSnapshotStore(Protocol):
    def save(
        self,
        market: str,
        category: str,
        market_date: str,
        market_status: str,
        payload: dict,
        generated_at: Optional[str] = None,
    ) -> ScreenerSnapshotRecord: ...

    def latest(
        self, market: str, category: str
    ) -> Optional[ScreenerSnapshotRecord]: ...

    def get_for_date(
        self, market: str, category: str, market_date: str
    ) -> Optional[ScreenerSnapshotRecord]: ...

    def has_for_date(
        self, market: str, market_date: str
    ) -> bool: ...


# --------------------------------------------------------------------------- #
# SQLite                                                                       #
# --------------------------------------------------------------------------- #
class SqliteScreenerSnapshotStore:
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
                CREATE TABLE IF NOT EXISTS screener_snapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    market TEXT NOT NULL,
                    category TEXT NOT NULL,
                    generated_at TEXT NOT NULL,
                    market_date TEXT NOT NULL,
                    market_status TEXT NOT NULL,
                    payload_json TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE INDEX IF NOT EXISTS ix_screener_snapshots_key
                ON screener_snapshots (market, category, id)
                """
            )
            conn.execute(
                """
                CREATE INDEX IF NOT EXISTS ix_screener_snapshots_date
                ON screener_snapshots (market, market_date)
                """
            )

    def save(
        self,
        market: str,
        category: str,
        market_date: str,
        market_status: str,
        payload: dict,
        generated_at: Optional[str] = None,
    ) -> ScreenerSnapshotRecord:
        gen = generated_at or _now_iso()
        payload_json = json.dumps(payload, default=str)
        with self._lock, self._connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO screener_snapshots
                    (market, category, generated_at, market_date,
                     market_status, payload_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    market,
                    category,
                    gen,
                    market_date,
                    market_status,
                    payload_json,
                ),
            )
            new_id = int(cur.lastrowid)
        return ScreenerSnapshotRecord(
            id=new_id,
            market=market,
            category=category,
            generated_at=gen,
            market_date=market_date,
            market_status=market_status,
            payload_json=payload_json,
        )

    def latest(
        self, market: str, category: str
    ) -> Optional[ScreenerSnapshotRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM screener_snapshots
                WHERE market = ? AND category = ?
                ORDER BY id DESC LIMIT 1
                """,
                (market, category),
            ).fetchone()
        return _row_to_record(row)

    def get_for_date(
        self, market: str, category: str, market_date: str
    ) -> Optional[ScreenerSnapshotRecord]:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM screener_snapshots
                WHERE market = ? AND category = ? AND market_date = ?
                ORDER BY id DESC LIMIT 1
                """,
                (market, category, market_date),
            ).fetchone()
        return _row_to_record(row)

    def has_for_date(self, market: str, market_date: str) -> bool:
        with self._lock, self._connect() as conn:
            row = conn.execute(
                """
                SELECT 1 FROM screener_snapshots
                WHERE market = ? AND market_date = ? LIMIT 1
                """,
                (market, market_date),
            ).fetchone()
        return row is not None


def _row_to_record(row) -> Optional[ScreenerSnapshotRecord]:
    if row is None:
        return None
    return ScreenerSnapshotRecord(
        id=int(row["id"]),
        market=row["market"],
        category=row["category"],
        generated_at=row["generated_at"],
        market_date=row["market_date"],
        market_status=row["market_status"],
        payload_json=row["payload_json"],
    )


# --------------------------------------------------------------------------- #
# In-memory (tests)                                                            #
# --------------------------------------------------------------------------- #
class InMemoryScreenerSnapshotStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._rows: List[ScreenerSnapshotRecord] = []
        self._next_id = 1
        # Counts how many times save() ran; tests assert no re-screen.
        self.save_count = 0

    def save(
        self,
        market: str,
        category: str,
        market_date: str,
        market_status: str,
        payload: dict,
        generated_at: Optional[str] = None,
    ) -> ScreenerSnapshotRecord:
        with self._lock:
            rec = ScreenerSnapshotRecord(
                id=self._next_id,
                market=market,
                category=category,
                generated_at=generated_at or _now_iso(),
                market_date=market_date,
                market_status=market_status,
                payload_json=json.dumps(payload, default=str),
            )
            self._next_id += 1
            self.save_count += 1
            self._rows.append(rec)
            return rec

    def latest(
        self, market: str, category: str
    ) -> Optional[ScreenerSnapshotRecord]:
        with self._lock:
            for rec in reversed(self._rows):
                if rec.market == market and rec.category == category:
                    return rec
        return None

    def get_for_date(
        self, market: str, category: str, market_date: str
    ) -> Optional[ScreenerSnapshotRecord]:
        with self._lock:
            for rec in reversed(self._rows):
                if (
                    rec.market == market
                    and rec.category == category
                    and rec.market_date == market_date
                ):
                    return rec
        return None

    def has_for_date(self, market: str, market_date: str) -> bool:
        with self._lock:
            return any(
                rec.market == market and rec.market_date == market_date
                for rec in self._rows
            )
