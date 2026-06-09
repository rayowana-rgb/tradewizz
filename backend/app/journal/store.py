"""SQLite persistence for the Portfolio Journal.

One table: journal_entries. Each row is a journaled simulated position. A BUY
inserts an OPEN entry with its snapshot; a SELL closes the oldest matching OPEN
entry (FIFO) and records the realized return. No accounting here — quantities
and prices mirror what the simulation already executed.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Protocol

from ..models import Market
from .models import JournalEntry


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_db_path() -> str:
    env = os.environ.get("TRADEWIZZ_JOURNAL_DB_PATH")
    if env:
        return env
    base = os.environ.get("TRADEWIZZ_DB_PATH")
    if base:
        return str(Path(base).with_name("journal.db"))
    return str(
        Path(__file__).resolve().parent.parent.parent / "data" / "journal.db"
    )


class JournalStore(Protocol):
    def add_buy(self, entry: JournalEntry) -> JournalEntry: ...
    def close_sell(
        self, user_id: int, symbol: str, market: Market,
        quantity: float, sell_price: float, sell_date: str,
    ) -> List[JournalEntry]: ...
    def list_entries(self, user_id: int) -> List[JournalEntry]: ...
    def clear_user(self, user_id: int) -> None: ...


def _row_to_entry(row: sqlite3.Row) -> JournalEntry:
    return JournalEntry(
        id=row["id"],
        user_id=row["user_id"],
        symbol=row["symbol"],
        market=Market(row["market"]),
        buy_date=row["buy_date"],
        buy_price=row["buy_price"],
        quantity=row["quantity"],
        score=row["score"],
        signal=row["signal"],
        radar_rank=row["radar_rank"],
        portfolio_health=row["portfolio_health"],
        sell_date=row["sell_date"],
        sell_price=row["sell_price"],
        realized_return=row["realized_return"],
        status=row["status"],
    )


class SqliteJournalStore:
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
                CREATE TABLE IF NOT EXISTS journal_entries (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id          INTEGER NOT NULL,
                    symbol           TEXT NOT NULL,
                    market           TEXT NOT NULL,
                    buy_date         TEXT NOT NULL,
                    buy_price        REAL NOT NULL DEFAULT 0,
                    quantity         REAL NOT NULL DEFAULT 0,
                    score            REAL NOT NULL DEFAULT 0,
                    signal           TEXT NOT NULL DEFAULT 'HOLD',
                    radar_rank       INTEGER,
                    portfolio_health REAL NOT NULL DEFAULT 0,
                    sell_date        TEXT,
                    sell_price       REAL,
                    realized_return  REAL,
                    status           TEXT NOT NULL DEFAULT 'OPEN'
                );
                CREATE INDEX IF NOT EXISTS idx_journal_user
                    ON journal_entries (user_id, status);
                """
            )
            conn.commit()

    def add_buy(self, entry: JournalEntry) -> JournalEntry:
        with self._lock:
            conn = self._conn()
            cur = conn.execute(
                """INSERT INTO journal_entries
                   (user_id, symbol, market, buy_date, buy_price, quantity,
                    score, signal, radar_rank, portfolio_health, status)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'OPEN')""",
                (
                    entry.user_id, entry.symbol.upper(), entry.market.value,
                    entry.buy_date or _now_iso(), entry.buy_price,
                    entry.quantity, entry.score, entry.signal,
                    entry.radar_rank, entry.portfolio_health,
                ),
            )
            conn.commit()
            entry.id = int(cur.lastrowid)
            entry.status = "OPEN"
        return entry

    def close_sell(
        self, user_id: int, symbol: str, market: Market,
        quantity: float, sell_price: float, sell_date: str,
    ) -> List[JournalEntry]:
        """Close OPEN entries FIFO up to ``quantity``; return the closed rows."""
        symbol = symbol.upper()
        remaining = quantity
        closed: List[JournalEntry] = []
        with self._lock:
            conn = self._conn()
            rows = conn.execute(
                """SELECT * FROM journal_entries
                   WHERE user_id = ? AND symbol = ? AND market = ?
                     AND status = 'OPEN'
                   ORDER BY id ASC""",
                (user_id, symbol, market.value),
            ).fetchall()
            for row in rows:
                if remaining <= 1e-9:
                    break
                entry = _row_to_entry(row)
                # Whole-entry FIFO close (partial fills keep it simple: an entry
                # is closed once the running sell quantity reaches it).
                remaining -= entry.quantity
                ret = (
                    (sell_price - entry.buy_price) / entry.buy_price * 100.0
                    if entry.buy_price > 0 else 0.0
                )
                conn.execute(
                    """UPDATE journal_entries
                       SET sell_date = ?, sell_price = ?, realized_return = ?,
                           status = 'CLOSED'
                       WHERE id = ?""",
                    (sell_date or _now_iso(), sell_price, round(ret, 2),
                     entry.id),
                )
                entry.sell_date = sell_date or _now_iso()
                entry.sell_price = sell_price
                entry.realized_return = round(ret, 2)
                entry.status = "CLOSED"
                closed.append(entry)
            conn.commit()
        return closed

    def list_entries(self, user_id: int) -> List[JournalEntry]:
        with self._lock:
            rows = self._conn().execute(
                """SELECT * FROM journal_entries WHERE user_id = ?
                   ORDER BY id DESC""",
                (user_id,),
            ).fetchall()
        return [_row_to_entry(r) for r in rows]

    def clear_user(self, user_id: int) -> None:
        with self._lock:
            conn = self._conn()
            conn.execute(
                "DELETE FROM journal_entries WHERE user_id = ?", (user_id,)
            )
            conn.commit()
