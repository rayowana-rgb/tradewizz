"""Portfolio Journal service — snapshot on buy, close on sell, plus stats.

The journal is fed by a best-effort hook on the simulation order endpoint
(``on_trade``). On a BUY it snapshots the engine score + signal, the current
daily-pick (radar) rank, and the current portfolio-health score. On a SELL it
closes the matching OPEN entries FIFO and records the realized return.

All snapshot lookups are best-effort: a failure never blocks the (already
executed) simulated trade. No broker contact. No accounting changes.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Protocol, Tuple

from ..models import Market, ScreenerMatch
from .models import JournalEntry, JournalList, JournalStats
from .store import JournalStore

ScoreProvider = Callable[[str, Market], Optional[ScreenerMatch]]


class HealthLike(Protocol):
    def health(self, user_id: int): ...


class RadarLike(Protocol):
    def daily(self): ...


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class JournalService:
    def __init__(
        self,
        store: JournalStore,
        score_provider: Optional[ScoreProvider] = None,
        health_service: Optional[HealthLike] = None,
        radar_service: Optional[RadarLike] = None,
    ):
        self._store = store
        self._score = score_provider
        self._health = health_service
        self._radar = radar_service

    # -- snapshot helpers (all best-effort) ------------------------------
    def _score_signal(self, symbol: str, market: Market) -> Tuple[float, str]:
        if self._score is None:
            return 0.0, "HOLD"
        try:
            match = self._score(symbol, market)
        except Exception:  # noqa: BLE001
            match = None
        if match is None:
            return 0.0, "HOLD"
        return float(match.score), (match.signal or "HOLD")

    def _radar_rank(self, symbol: str, market: Market) -> Optional[int]:
        if self._radar is None:
            return None
        try:
            picks = self._radar.daily().picks
        except Exception:  # noqa: BLE001
            return None
        for p in picks:
            if p.symbol.upper() == symbol.upper() and p.market == market:
                return p.rank
        return None

    def _portfolio_health(self, user_id: int) -> float:
        if self._health is None:
            return 0.0
        try:
            return float(self._health.health(user_id).health_score)
        except Exception:  # noqa: BLE001
            return 0.0

    # -- trade hook ------------------------------------------------------
    def on_trade(
        self,
        user_id: int,
        symbol: str,
        market: Market,
        side: str,
        quantity: float,
        price: float,
    ) -> None:
        """Record a journal effect for an already-executed simulated trade."""
        try:
            side = (side or "").upper()
            if side == "BUY":
                score, signal = self._score_signal(symbol, market)
                self._store.add_buy(JournalEntry(
                    user_id=user_id,
                    symbol=symbol,
                    market=market,
                    buy_date=_now_iso(),
                    buy_price=price,
                    quantity=quantity,
                    score=score,
                    signal=signal,
                    radar_rank=self._radar_rank(symbol, market),
                    portfolio_health=self._portfolio_health(user_id),
                ))
            elif side == "SELL":
                self._store.close_sell(
                    user_id, symbol, market, quantity, price, _now_iso()
                )
        except Exception:  # noqa: BLE001 - journaling never blocks a trade
            return

    # -- reads -----------------------------------------------------------
    def entries(self, user_id: int) -> JournalList:
        return JournalList(entries=self._store.list_entries(user_id))

    def stats(self, user_id: int) -> JournalStats:
        entries = self._store.list_entries(user_id)
        closed = [e for e in entries if e.status == "CLOSED"
                  and e.realized_return is not None]
        open_n = sum(1 for e in entries if e.status == "OPEN")

        if not closed:
            return JournalStats(
                user_id=user_id,
                total_trades=0,
                open_positions=open_n,
            )

        wins = [e for e in closed if (e.realized_return or 0.0) > 0]
        losses = [e for e in closed if (e.realized_return or 0.0) <= 0]
        win_rate = len(wins) / len(closed) * 100.0
        avg_gain = (
            sum(e.realized_return for e in wins) / len(wins) if wins else 0.0
        )
        avg_loss = (
            sum(e.realized_return for e in losses) / len(losses)
            if losses else 0.0
        )
        best = max(closed, key=lambda e: e.realized_return or 0.0)
        worst = min(closed, key=lambda e: e.realized_return or 0.0)

        return JournalStats(
            user_id=user_id,
            total_trades=len(closed),
            open_positions=open_n,
            win_rate=round(win_rate, 1),
            average_gain=round(avg_gain, 2),
            average_loss=round(avg_loss, 2),
            best_trade=best,
            worst_trade=worst,
        )
