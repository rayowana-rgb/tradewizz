"""SQLite persistence for Auto Watchlist AI.

Two tables:
  * auto_watchlist_settings  — one row per user (the AutoWatchlistSettings).
  * auto_watchlist_applied   — applied suggestions with source metadata.

No watchlist items are stored here (the watchlist itself stays client-side); we
only persist per-user settings + an audit trail of AI-applied symbols so the
backend can avoid re-suggesting and surface source metadata. No accounting.
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Protocol

from ..models import Market
from .models import AppliedSuggestion, AutoWatchlistSettings


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_db_path() -> str:
    env = os.environ.get("TRADEWIZZ_AUTO_WATCHLIST_DB_PATH")
    if env:
        return env
    base = os.environ.get("TRADEWIZZ_DB_PATH")
    if base:
        return str(Path(base).with_name("auto_watchlist.db"))
    return str(
        Path(__file__).resolve().parent.parent.parent
        / "data" / "auto_watchlist.db"
    )


class AutoWatchlistStore(Protocol):
    def get_settings(self, user_id: int) -> Optional[AutoWatchlistSettings]: ...
    def save_settings(
        self, user_id: int, settings: AutoWatchlistSettings
    ) -> None: ...
    def add_applied(
        self, user_id: int, applied: AppliedSuggestion
    ) -> None: ...
    def applied_symbols(self, user_id: int) -> List[str]: ...
    def applied_today(self, user_id: int) -> int: ...
    def clear_user(self, user_id: int) -> None: ...


class SqliteAutoWatchlistStore:
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
                CREATE TABLE IF NOT EXISTS auto_watchlist_settings (
                    user_id            INTEGER PRIMARY KEY,
                    enabled            INTEGER NOT NULL DEFAULT 1,
                    markets            TEXT NOT NULL DEFAULT '[]',
                    min_score          REAL NOT NULL DEFAULT 85,
                    max_per_day        INTEGER NOT NULL DEFAULT 10,
                    include_multibagger INTEGER NOT NULL DEFAULT 1,
                    include_daily_picks INTEGER NOT NULL DEFAULT 1
                );
                CREATE TABLE IF NOT EXISTS auto_watchlist_applied (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id     INTEGER NOT NULL,
                    symbol      TEXT NOT NULL,
                    market      TEXT NOT NULL,
                    name        TEXT NOT NULL DEFAULT '',
                    source      TEXT NOT NULL DEFAULT 'AUTO_WATCHLIST_AI',
                    reason      TEXT NOT NULL DEFAULT '',
                    score_at_added REAL NOT NULL DEFAULT 0,
                    regime_at_added TEXT NOT NULL DEFAULT 'NEUTRAL',
                    added_at    TEXT NOT NULL,
                    added_day   TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_aw_applied_user
                    ON auto_watchlist_applied (user_id);
                """
            )
            conn.commit()

    # -- settings --------------------------------------------------------
    def get_settings(self, user_id: int) -> Optional[AutoWatchlistSettings]:
        with self._lock:
            row = self._conn().execute(
                "SELECT * FROM auto_watchlist_settings WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        if row is None:
            return None
        markets = []
        try:
            markets = [Market(m) for m in json.loads(row["markets"] or "[]")]
        except (ValueError, json.JSONDecodeError):
            markets = []
        return AutoWatchlistSettings(
            enabled=bool(row["enabled"]),
            markets=markets,
            min_score=row["min_score"],
            max_per_day=row["max_per_day"],
            include_multibagger=bool(row["include_multibagger"]),
            include_daily_picks=bool(row["include_daily_picks"]),
        )

    def save_settings(
        self, user_id: int, settings: AutoWatchlistSettings
    ) -> None:
        markets = json.dumps([m.value for m in settings.markets])
        with self._lock:
            conn = self._conn()
            conn.execute(
                """INSERT INTO auto_watchlist_settings
                   (user_id, enabled, markets, min_score, max_per_day,
                    include_multibagger, include_daily_picks)
                   VALUES (?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(user_id) DO UPDATE SET
                     enabled=excluded.enabled,
                     markets=excluded.markets,
                     min_score=excluded.min_score,
                     max_per_day=excluded.max_per_day,
                     include_multibagger=excluded.include_multibagger,
                     include_daily_picks=excluded.include_daily_picks""",
                (
                    user_id, int(settings.enabled), markets,
                    settings.min_score, settings.max_per_day,
                    int(settings.include_multibagger),
                    int(settings.include_daily_picks),
                ),
            )
            conn.commit()

    # -- applied audit trail ---------------------------------------------
    def add_applied(self, user_id: int, applied: AppliedSuggestion) -> None:
        day = (applied.added_at or _now_iso())[:10]
        with self._lock:
            conn = self._conn()
            conn.execute(
                """INSERT INTO auto_watchlist_applied
                   (user_id, symbol, market, name, source, reason,
                    score_at_added, regime_at_added, added_at, added_day)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    user_id, applied.symbol.upper(), applied.market.value,
                    applied.name, applied.source, applied.reason,
                    applied.score_at_added, applied.market_regime_at_added,
                    applied.added_at or _now_iso(), day,
                ),
            )
            conn.commit()

    def applied_symbols(self, user_id: int) -> List[str]:
        """Return "MARKET:SYMBOL" keys already applied by the AI for a user."""
        with self._lock:
            rows = self._conn().execute(
                "SELECT market, symbol FROM auto_watchlist_applied "
                "WHERE user_id = ?",
                (user_id,),
            ).fetchall()
        return [f"{r['market']}:{r['symbol']}" for r in rows]

    def applied_today(self, user_id: int) -> int:
        today = _now_iso()[:10]
        with self._lock:
            row = self._conn().execute(
                "SELECT COUNT(*) AS c FROM auto_watchlist_applied "
                "WHERE user_id = ? AND added_day = ?",
                (user_id, today),
            ).fetchone()
        return int(row["c"]) if row else 0

    def clear_user(self, user_id: int) -> None:
        with self._lock:
            conn = self._conn()
            conn.execute(
                "DELETE FROM auto_watchlist_settings WHERE user_id = ?",
                (user_id,),
            )
            conn.execute(
                "DELETE FROM auto_watchlist_applied WHERE user_id = ?",
                (user_id,),
            )
            conn.commit()
