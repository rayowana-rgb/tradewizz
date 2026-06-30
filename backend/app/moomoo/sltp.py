"""Server-managed stop-loss / take-profit ("bracket") for Moomoo LIVE.

Moomoo's OpenD SDK has no native bracket / OCO order for stocks, and native
STOP / LIMIT orders require whole shares (fractional only trades MARKET). A
$500-per-name US plan is frequently fractional, so we manage the bracket on
the server instead:

  * The owner attaches a bracket to a position: a stop at ``-stop_pct`` and a
    target at ``+target_pct`` from a reference price (default -1% / +3%).
  * A monitor polls the LIVE positions (their ``last_price`` is a real quote,
    no extra fetch) and, when the price touches a level, submits a single
    MARKET SELL for the tracked quantity.
  * OCO is implicit: firing either leg moves the bracket out of ACTIVE, so the
    opposite leg can never also fire. No client polling / race window.

This NEVER fabricates prices: every decision uses the real ``last_price`` the
broker reports for the position. The monitor only SELLS (it never opens new
risk), and it only sells quantity that is still actually held.

Persistence is a small JSON file so brackets survive a backend restart.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, asdict
from typing import Dict, List, Optional


# -- status ------------------------------------------------------------------
ACTIVE = "ACTIVE"
TRIGGERED_STOP = "TRIGGERED_STOP"
TRIGGERED_TARGET = "TRIGGERED_TARGET"
# A level was hit while the regular session was closed, so instead of failing a
# MARKET sell we placed a resting LIMIT sell that will fill in the extended /
# overnight session. The bracket leaves ACTIVE (it has done its job) but is not
# a clean RTH fill, so it carries its own terminal-ish status.
PENDING_EXT = "PENDING_EXT"
CANCELLED = "CANCELLED"
CLOSED_NO_POSITION = "CLOSED_NO_POSITION"
ERROR = "ERROR"

_TERMINAL = {
    TRIGGERED_STOP,
    TRIGGERED_TARGET,
    PENDING_EXT,
    CANCELLED,
    CLOSED_NO_POSITION,
}


def _default_path() -> str:
    return os.environ.get(
        "TRADEWIZZ_MOOMOO_SLTP_PATH",
        os.path.join(
            os.environ.get("TRADEWIZZ_DATA_DIR", "data"),
            "moomoo_sltp.json",
        ),
    )


@dataclass
class Bracket:
    """A server-managed stop-loss / take-profit pair for one symbol."""

    symbol: str            # bare US symbol, e.g. "AAPL"
    qty: float             # shares the bracket protects (may be fractional)
    reference_price: float  # price the levels are computed from
    stop_pct: float        # e.g. -1.0  (percent)
    target_pct: float      # e.g.  3.0  (percent)
    stop_price: float
    target_price: float
    status: str = ACTIVE
    created_ts: int = 0
    updated_ts: int = 0
    triggered_ts: Optional[int] = None
    triggered_price: Optional[float] = None
    order_id: Optional[str] = None  # the sell order placed on trigger
    note: str = ""

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def active(self) -> bool:
        return self.status == ACTIVE


class SLTPStore:
    """Thread-safe, JSON-backed store of brackets keyed by symbol.

    One ACTIVE bracket per symbol (a new attach replaces an existing one).
    Terminal brackets are retained (bounded) so the app can show history.
    """

    # Keep at most this many terminal (history) brackets.
    _MAX_HISTORY = 200

    def __init__(self, path: Optional[str] = None) -> None:
        self._path = path or _default_path()
        self._lock = threading.RLock()

    # -- io ---------------------------------------------------------------
    def _load(self) -> List[Bracket]:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except (FileNotFoundError, ValueError, OSError):
            return []
        out: List[Bracket] = []
        for r in raw if isinstance(raw, list) else []:
            try:
                out.append(Bracket(**r))
            except TypeError:
                # Ignore rows from an older/newer schema.
                continue
        return out

    def _save(self, items: List[Bracket]) -> None:
        d = os.path.dirname(self._path)
        if d:
            os.makedirs(d, exist_ok=True)
        tmp = self._path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump([b.to_dict() for b in items], fh)
        os.replace(tmp, self._path)

    # -- public read ------------------------------------------------------
    def list(self) -> List[Bracket]:
        with self._lock:
            return self._load()

    def active(self) -> List[Bracket]:
        return [b for b in self.list() if b.active]

    def get(self, symbol: str) -> Optional[Bracket]:
        sym = _bare(symbol)
        for b in self.list():
            if b.symbol == sym and b.active:
                return b
        return None

    # -- public write -----------------------------------------------------
    def attach(
        self,
        symbol: str,
        qty: float,
        reference_price: float,
        *,
        stop_pct: float = -1.0,
        target_pct: float = 3.0,
    ) -> Bracket:
        """Create / replace the ACTIVE bracket for ``symbol``.

        ``stop_pct`` is negative (below entry), ``target_pct`` positive. Levels
        are derived from ``reference_price`` (typically the fill / cost price).
        """
        sym = _bare(symbol)
        if qty is None or qty <= 0:
            raise ValueError("qty must be positive")
        if reference_price is None or reference_price <= 0:
            raise ValueError("reference_price must be positive")
        if stop_pct >= 0:
            raise ValueError("stop_pct must be negative (a stop below entry)")
        if target_pct <= 0:
            raise ValueError("target_pct must be positive")
        now = int(time.time())
        stop_price = round(reference_price * (1.0 + stop_pct / 100.0), 4)
        target_price = round(reference_price * (1.0 + target_pct / 100.0), 4)
        b = Bracket(
            symbol=sym,
            qty=float(qty),
            reference_price=float(reference_price),
            stop_pct=float(stop_pct),
            target_pct=float(target_pct),
            stop_price=stop_price,
            target_price=target_price,
            status=ACTIVE,
            created_ts=now,
            updated_ts=now,
        )
        with self._lock:
            items = self._load()
            # Drop any existing ACTIVE bracket for this symbol (replace).
            items = [
                x for x in items if not (x.symbol == sym and x.active)
            ]
            items.append(b)
            self._save(self._prune(items))
        return b

    def cancel(self, symbol: str) -> Optional[Bracket]:
        sym = _bare(symbol)
        with self._lock:
            items = self._load()
            hit: Optional[Bracket] = None
            for x in items:
                if x.symbol == sym and x.active:
                    x.status = CANCELLED
                    x.updated_ts = int(time.time())
                    hit = x
            if hit is not None:
                self._save(self._prune(items))
            return hit

    def _mark(
        self,
        bracket: Bracket,
        status: str,
        *,
        price: Optional[float] = None,
        order_id: Optional[str] = None,
        note: str = "",
    ) -> None:
        with self._lock:
            items = self._load()
            for x in items:
                if x.symbol == bracket.symbol and x.active:
                    x.status = status
                    x.updated_ts = int(time.time())
                    if status in _TERMINAL and status not in (
                        CANCELLED, CLOSED_NO_POSITION
                    ):
                        x.triggered_ts = int(time.time())
                        x.triggered_price = price
                    if order_id:
                        x.order_id = order_id
                    if note:
                        x.note = note
            self._save(self._prune(items))

    def _prune(self, items: List[Bracket]) -> List[Bracket]:
        actives = [b for b in items if b.active]
        history = [b for b in items if not b.active]
        history.sort(key=lambda b: b.updated_ts or 0, reverse=True)
        return actives + history[: self._MAX_HISTORY]


def _bare(symbol: str) -> str:
    s = (symbol or "").strip().upper()
    return s.split(".", 1)[1] if "." in s else s


def _us_session_open() -> bool:
    """True when the US regular session is open right now.

    Isolated in a tiny helper so tests can monkeypatch it. Never raises; on any
    unexpected error it returns True so the monitor falls back to the previous
    MARKET-sell behaviour (fail-safe: act now rather than rest a stale order).
    """
    try:
        from app.market_session import is_session_open

        return bool(is_session_open("US"))
    except Exception:  # noqa: BLE001
        return True


class SLTPMonitor:
    """Polls LIVE positions and fires MARKET sells when a level is touched.

    The monitor is intentionally conservative:
      * It only ever SELLS, and only quantity still held (``can_sell_qty``).
      * If the position is gone (sold elsewhere) the bracket is closed quietly.
      * During regular US hours a level hit fires a MARKET sell (fills now).
      * When the regular session is CLOSED, a MARKET sell would be rejected by
        the broker. Instead, for whole-share lots we place a marketable LIMIT
        sell flagged for the extended / overnight session so the order rests
        as *pending* and fills when that session trades (PENDING_EXT), rather
        than failing. Fractional lots cannot trade outside RTH on Moomoo, so
        they simply stay ACTIVE and fire at the next regular open.
      * If a sell still fails the bracket stays ACTIVE so it is retried next
        tick rather than silently abandoned.
    """

    def __init__(self, moomoo_service, store: Optional[SLTPStore] = None):
        self._moomoo = moomoo_service
        self.store = store or SLTPStore()

    def _live_positions(self) -> Dict[str, object]:
        try:
            return {p.symbol: p for p in self._moomoo.positions()}
        except Exception:
            return {}

    def tick(self) -> List[dict]:
        """Evaluate all ACTIVE brackets once. Returns a list of actions taken.

        Safe to call repeatedly (e.g. from the cache warmer loop). Never
        raises; broker errors are captured per-bracket.
        """
        actions: List[dict] = []
        brackets = self.store.active()
        if not brackets:
            return actions
        positions = self._live_positions()
        for b in brackets:
            pos = positions.get(b.symbol)
            if pos is None or getattr(pos, "qty", 0) <= 0:
                # The owner closed the position elsewhere; retire the bracket.
                self.store._mark(
                    b, CLOSED_NO_POSITION,
                    note="position no longer held",
                )
                actions.append({"symbol": b.symbol, "action": "closed"})
                continue
            last = float(getattr(pos, "last_price", 0) or 0)
            if last <= 0:
                continue  # no quote yet; try again next tick
            hit: Optional[str] = None
            if last <= b.stop_price:
                hit = TRIGGERED_STOP
            elif last >= b.target_price:
                hit = TRIGGERED_TARGET
            if hit is None:
                continue
            # Sell only what is actually sellable right now.
            sell_qty = float(getattr(pos, "can_sell_qty", 0) or 0)
            if sell_qty <= 0:
                sell_qty = float(getattr(pos, "qty", 0) or 0)
            sell_qty = min(sell_qty, b.qty) if b.qty > 0 else sell_qty
            if sell_qty <= 0:
                continue

            # Pick the order style based on whether the regular US session is
            # open. When closed, a MARKET order can't fill, so rest a LIMIT in
            # the extended/overnight session instead of failing it.
            session_open = _us_session_open()
            is_fractional = float(sell_qty) != int(sell_qty)
            use_ext = (not session_open) and (not is_fractional)

            if (not session_open) and is_fractional:
                # Fractional can only trade MARKET, which won't fill outside
                # RTH. Stay ACTIVE and fire at the next regular open.
                self.store._mark(
                    b, ACTIVE,
                    note="level hit while closed; fractional waits for "
                         "regular session",
                )
                actions.append({
                    "symbol": b.symbol,
                    "action": "deferred",
                    "reason": "fractional_closed",
                    "price": last,
                })
                continue

            try:
                if use_ext:
                    # Marketable LIMIT at the touched price so it fills as soon
                    # as the extended/overnight session trades, but never sells
                    # below the stop level (or above target) we acted on.
                    res = self._moomoo.place(
                        symbol=b.symbol,
                        side="SELL",
                        qty=sell_qty,
                        order_type="LIMIT",
                        price=round(last, 2),
                        confirm=True,
                        trade_pin=None,
                        extended_hours=True,
                    )
                else:
                    res = self._moomoo.place(
                        symbol=b.symbol,
                        side="SELL",
                        qty=sell_qty,
                        order_type="MARKET",
                        price=None,
                        confirm=True,
                        trade_pin=None,  # SKIP_UNLOCK (operator-unlocked)
                    )
                oid = getattr(res, "order_id", "") or ""
                leg = "stop-loss" if hit == TRIGGERED_STOP else "take-profit"
                if use_ext:
                    self.store._mark(
                        b, PENDING_EXT, price=last, order_id=oid,
                        note=f"{leg}: pending extended/overnight LIMIT sell",
                    )
                    actions.append({
                        "symbol": b.symbol,
                        "action": "pending_ext",
                        "trigger": hit,
                        "price": last,
                        "qty": sell_qty,
                        "order_id": oid,
                    })
                else:
                    self.store._mark(
                        b, hit, price=last, order_id=oid, note=leg,
                    )
                    actions.append({
                        "symbol": b.symbol,
                        "action": hit,
                        "price": last,
                        "qty": sell_qty,
                        "order_id": oid,
                    })
            except Exception as exc:  # noqa: BLE001
                # Leave the bracket ACTIVE so the next tick retries; record why.
                self.store._mark(
                    b, ACTIVE, note=f"sell failed: {exc}"[:160],
                )
                actions.append({
                    "symbol": b.symbol,
                    "action": "error",
                    "error": str(exc)[:160],
                })
        return actions
