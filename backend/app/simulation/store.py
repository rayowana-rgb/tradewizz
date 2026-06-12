"""SQLite persistence for the simulated portfolio (per user).

Three tables: sim_accounts (cash + realized P/L), sim_positions (open lots),
sim_trades (immutable trade log). Thread-safe via a lock + per-call connection.
No broker tables, no external state.
"""

from __future__ import annotations

import os
import sqlite3
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_db_path() -> str:
    env = os.environ.get("TRADEWIZZ_SIM_DB_PATH")
    if env:
        return env
    # Co-locate with the main app DB by default.
    base = os.environ.get("TRADEWIZZ_DB_PATH")
    if base:
        return str(Path(base).with_name("simulation.db"))
    return str(
        Path(__file__).resolve().parent.parent.parent / "data" / "simulation.db"
    )


@dataclass
class AccountRow:
    user_id: int
    cash: float
    realized_pnl: float
    currency: str
    created_at: str
    updated_at: str


@dataclass
class PositionRow:
    user_id: int
    symbol: str
    market: str
    quantity: float
    average_cost: float
    realized_pnl: float
    created_at: str
    updated_at: str


@dataclass
class TradeRow:
    id: int
    user_id: int
    order_id: str
    symbol: str
    market: str
    side: str
    quantity: float
    price: float
    value: float
    realized_pnl: float
    created_at: str


class SimulationStore:
    """SQLite-backed store. A single instance is shared across requests."""

    def __init__(self, db_path: Optional[str] = None):
        self._path = db_path or _default_db_path()
        if self._path != ":memory:":
            Path(self._path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        # For :memory: we must keep one shared connection alive.
        self._shared = (
            sqlite3.connect(self._path, check_same_thread=False)
            if self._path == ":memory:"
            else None
        )
        self._init_schema()

    # -- connection ------------------------------------------------------
    def _conn(self) -> sqlite3.Connection:
        if self._shared is not None:
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
                CREATE TABLE IF NOT EXISTS sim_accounts (
                    user_id     INTEGER PRIMARY KEY,
                    cash        REAL NOT NULL,
                    realized_pnl REAL NOT NULL DEFAULT 0,
                    currency    TEXT NOT NULL DEFAULT 'USD',
                    created_at  TEXT NOT NULL,
                    updated_at  TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sim_positions (
                    user_id      INTEGER NOT NULL,
                    symbol       TEXT NOT NULL,
                    market       TEXT NOT NULL,
                    quantity     REAL NOT NULL DEFAULT 0,
                    average_cost REAL NOT NULL DEFAULT 0,
                    realized_pnl REAL NOT NULL DEFAULT 0,
                    created_at   TEXT NOT NULL,
                    updated_at   TEXT NOT NULL,
                    PRIMARY KEY (user_id, symbol, market)
                );
                CREATE TABLE IF NOT EXISTS sim_trades (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id      INTEGER NOT NULL,
                    order_id     TEXT NOT NULL,
                    symbol       TEXT NOT NULL,
                    market       TEXT NOT NULL,
                    side         TEXT NOT NULL,
                    quantity     REAL NOT NULL,
                    price        REAL NOT NULL,
                    value        REAL NOT NULL,
                    realized_pnl REAL NOT NULL DEFAULT 0,
                    created_at   TEXT NOT NULL
                );
                """
            )
            conn.commit()
            if self._shared is None:
                conn.close()

    # -- accounts --------------------------------------------------------
    def get_or_create_account(
        self, user_id: int, initial_cash: float, currency: str = "USD"
    ) -> AccountRow:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT * FROM sim_accounts WHERE user_id=?", (user_id,)
            ).fetchone()
            if row is None:
                now = _now_iso()
                conn.execute(
                    "INSERT INTO sim_accounts "
                    "(user_id, cash, realized_pnl, currency, created_at, "
                    "updated_at) VALUES (?,?,?,?,?,?)",
                    (user_id, initial_cash, 0.0, currency, now, now),
                )
                conn.commit()
                row = conn.execute(
                    "SELECT * FROM sim_accounts WHERE user_id=?", (user_id,)
                ).fetchone()
            result = self._account_row(row)
            if self._shared is None:
                conn.close()
            return result

    def update_account(
        self, user_id: int, cash: float, realized_pnl: float
    ) -> None:
        with self._lock:
            conn = self._conn()
            conn.execute(
                "UPDATE sim_accounts SET cash=?, realized_pnl=?, updated_at=? "
                "WHERE user_id=?",
                (cash, realized_pnl, _now_iso(), user_id),
            )
            conn.commit()
            if self._shared is None:
                conn.close()

    # -- positions -------------------------------------------------------
    def list_positions(self, user_id: int) -> List[PositionRow]:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT * FROM sim_positions WHERE user_id=? AND quantity>0 "
                "ORDER BY symbol",
                (user_id,),
            ).fetchall()
            out = [self._position_row(r) for r in rows]
            if self._shared is None:
                conn.close()
            return out

    def get_position(
        self, user_id: int, symbol: str, market: str
    ) -> Optional[PositionRow]:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT * FROM sim_positions WHERE user_id=? AND symbol=? "
                "AND market=?",
                (user_id, symbol, market),
            ).fetchone()
            out = self._position_row(row) if row else None
            if self._shared is None:
                conn.close()
            return out

    def upsert_position(
        self,
        user_id: int,
        symbol: str,
        market: str,
        quantity: float,
        average_cost: float,
        realized_pnl: float,
    ) -> None:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            now = _now_iso()
            existing = conn.execute(
                "SELECT created_at FROM sim_positions WHERE user_id=? AND "
                "symbol=? AND market=?",
                (user_id, symbol, market),
            ).fetchone()
            created = existing["created_at"] if existing else now
            conn.execute(
                "INSERT INTO sim_positions (user_id, symbol, market, quantity, "
                "average_cost, realized_pnl, created_at, updated_at) "
                "VALUES (?,?,?,?,?,?,?,?) "
                "ON CONFLICT(user_id, symbol, market) DO UPDATE SET "
                "quantity=excluded.quantity, average_cost=excluded.average_cost, "
                "realized_pnl=excluded.realized_pnl, updated_at=excluded.updated_at",
                (user_id, symbol, market, quantity, average_cost, realized_pnl,
                 created, now),
            )
            conn.commit()
            if self._shared is None:
                conn.close()

    def delete_position(self, user_id: int, symbol: str, market: str) -> None:
        with self._lock:
            conn = self._conn()
            conn.execute(
                "DELETE FROM sim_positions WHERE user_id=? AND symbol=? AND "
                "market=?",
                (user_id, symbol, market),
            )
            conn.commit()
            if self._shared is None:
                conn.close()

    # -- trades ----------------------------------------------------------
    def add_trade(
        self,
        user_id: int,
        order_id: str,
        symbol: str,
        market: str,
        side: str,
        quantity: float,
        price: float,
        value: float,
        realized_pnl: float,
    ) -> TradeRow:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            now = _now_iso()
            cur = conn.execute(
                "INSERT INTO sim_trades (user_id, order_id, symbol, market, "
                "side, quantity, price, value, realized_pnl, created_at) "
                "VALUES (?,?,?,?,?,?,?,?,?,?)",
                (user_id, order_id, symbol, market, side, quantity, price,
                 value, realized_pnl, now),
            )
            conn.commit()
            tid = cur.lastrowid
            row = conn.execute(
                "SELECT * FROM sim_trades WHERE id=?", (tid,)
            ).fetchone()
            out = self._trade_row(row)
            if self._shared is None:
                conn.close()
            return out

    def list_trades(self, user_id: int, limit: int = 200) -> List[TradeRow]:
        with self._lock:
            conn = self._conn()
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT * FROM sim_trades WHERE user_id=? ORDER BY id DESC "
                "LIMIT ?",
                (user_id, limit),
            ).fetchall()
            out = [self._trade_row(r) for r in rows]
            if self._shared is None:
                conn.close()
            return out

    # -- reset -----------------------------------------------------------
    def reset(self, user_id: int, initial_cash: float, currency: str = "USD") -> None:
        with self._lock:
            conn = self._conn()
            now = _now_iso()
            conn.execute("DELETE FROM sim_positions WHERE user_id=?", (user_id,))
            conn.execute("DELETE FROM sim_trades WHERE user_id=?", (user_id,))
            conn.execute(
                "INSERT INTO sim_accounts (user_id, cash, realized_pnl, "
                "currency, created_at, updated_at) VALUES (?,?,?,?,?,?) "
                "ON CONFLICT(user_id) DO UPDATE SET cash=excluded.cash, "
                "realized_pnl=0, currency=excluded.currency, "
                "updated_at=excluded.updated_at",
                (user_id, initial_cash, 0.0, currency, now, now),
            )
            conn.commit()
            if self._shared is None:
                conn.close()

    # -- row mappers -----------------------------------------------------
    @staticmethod
    def _account_row(r) -> AccountRow:
        return AccountRow(
            user_id=r["user_id"], cash=r["cash"], realized_pnl=r["realized_pnl"],
            currency=r["currency"], created_at=r["created_at"],
            updated_at=r["updated_at"],
        )

    @staticmethod
    def _position_row(r) -> PositionRow:
        return PositionRow(
            user_id=r["user_id"], symbol=r["symbol"], market=r["market"],
            quantity=r["quantity"], average_cost=r["average_cost"],
            realized_pnl=r["realized_pnl"], created_at=r["created_at"],
            updated_at=r["updated_at"],
        )

    @staticmethod
    def _trade_row(r) -> TradeRow:
        return TradeRow(
            id=r["id"], user_id=r["user_id"], order_id=r["order_id"],
            symbol=r["symbol"], market=r["market"], side=r["side"],
            quantity=r["quantity"], price=r["price"], value=r["value"],
            realized_pnl=r["realized_pnl"], created_at=r["created_at"],
        )
