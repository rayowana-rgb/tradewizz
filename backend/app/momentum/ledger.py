"""Local ledger of momentum-strategy holdings.

The owner runs several strategies in ONE Moomoo account (momentum research,
bullish, manual, …). A momentum rebalance must only ever touch the positions
that momentum itself bought — never the other strategies' positions.

Moomoo tags every order with a ``remark``, but the position query does NOT
return the remark, and reading it back from order history is slow/spotty. So
this module keeps a small, thread-safe JSON ledger of the symbols momentum has
bought, updated on every momentum BUY/SELL. The ledger is the fast source of
truth; it is always intersected with the live positions at rebalance time so a
symbol the owner has since sold manually simply drops out.

"Start clean" (option A): only momentum purchases made from now on are tracked.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import asdict, dataclass
from typing import Dict, List, Optional

# The remark tag stamped on every momentum order at the broker, so the
# strategy is also identifiable from Moomoo's own order history if ever needed.
MOMENTUM_REMARK = "tw:momentum"


def _default_path() -> str:
    return os.environ.get(
        "TRADEWIZZ_MOMENTUM_LEDGER_PATH",
        os.path.join(
            os.environ.get("TRADEWIZZ_DATA_DIR", "data"),
            "momentum_holdings.json",
        ),
    )


@dataclass
class LedgerEntry:
    """One momentum holding: the symbol and the shares momentum bought."""

    symbol: str            # bare US symbol, e.g. "AAPL"
    qty: float             # net shares bought via momentum (may be fractional)
    first_bought_ts: int   # epoch seconds of the first momentum buy
    updated_ts: int        # epoch seconds of the last mutation

    def to_dict(self) -> dict:
        return asdict(self)


class MomentumLedger:
    """Thread-safe, JSON-backed set of momentum holdings keyed by symbol."""

    def __init__(self, path: Optional[str] = None) -> None:
        self._path = path or _default_path()
        self._lock = threading.RLock()

    # -- io ---------------------------------------------------------------
    def _load(self) -> Dict[str, LedgerEntry]:
        try:
            with open(self._path, "r", encoding="utf-8") as fh:
                raw = json.load(fh)
        except (FileNotFoundError, ValueError, OSError):
            return {}
        out: Dict[str, LedgerEntry] = {}
        for r in raw if isinstance(raw, list) else []:
            try:
                sym = str(r["symbol"]).upper()
                out[sym] = LedgerEntry(
                    symbol=sym,
                    qty=float(r.get("qty", 0.0)),
                    first_bought_ts=int(r.get("first_bought_ts", 0)),
                    updated_ts=int(r.get("updated_ts", 0)),
                )
            except (KeyError, TypeError, ValueError):
                continue
        return out

    def _save(self, entries: Dict[str, LedgerEntry]) -> None:
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        tmp = f"{self._path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump([e.to_dict() for e in entries.values()], fh)
        os.replace(tmp, self._path)

    # -- queries ----------------------------------------------------------
    def symbols(self) -> List[str]:
        with self._lock:
            return sorted(self._load().keys())

    def entries(self) -> List[LedgerEntry]:
        with self._lock:
            return sorted(self._load().values(), key=lambda e: e.symbol)

    def has(self, symbol: str) -> bool:
        with self._lock:
            return symbol.upper() in self._load()

    def last_rebalance_ts(self) -> Optional[int]:
        """Epoch seconds of the most recent momentum mutation (buy/sell).

        Every rebalance touches the ledger (records the buys/sells it makes), so
        the newest ``updated_ts`` across all entries is a faithful proxy for
        "when the strategy was last acted on". Returns None when the ledger is
        empty (no momentum position ever taken) -- callers treat that as
        "no rebalance clock yet" rather than fabricating a date.
        """
        with self._lock:
            entries = self._load()
        if not entries:
            return None
        return max(e.updated_ts for e in entries.values())

    # -- mutations --------------------------------------------------------
    def record_buy(self, symbol: str, qty: float) -> None:
        """Add ``qty`` shares of ``symbol`` to the momentum ledger."""
        sym = symbol.upper()
        if qty <= 0:
            return
        now = int(time.time())
        with self._lock:
            entries = self._load()
            existing = entries.get(sym)
            if existing is None:
                entries[sym] = LedgerEntry(
                    symbol=sym,
                    qty=qty,
                    first_bought_ts=now,
                    updated_ts=now,
                )
            else:
                existing.qty += qty
                existing.updated_ts = now
            self._save(entries)

    def record_sell(self, symbol: str, qty: Optional[float] = None) -> None:
        """Remove ``qty`` shares (or the whole holding if ``qty`` is None).

        A rebalance sells the entire momentum position for a symbol that fell
        out of the top-N, so the common case is a full close (qty=None).
        """
        sym = symbol.upper()
        now = int(time.time())
        with self._lock:
            entries = self._load()
            existing = entries.get(sym)
            if existing is None:
                return
            if qty is None or qty >= existing.qty:
                entries.pop(sym, None)
            else:
                existing.qty -= qty
                existing.updated_ts = now
            self._save(entries)
