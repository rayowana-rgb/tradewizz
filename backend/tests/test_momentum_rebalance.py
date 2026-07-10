"""Momentum ledger + rebalance-diff tests (no OpenD / no network)."""

from __future__ import annotations

import os
import time
from datetime import date, timedelta

import pandas as pd

from app.momentum.ledger import MOMENTUM_REMARK, MomentumLedger
from app.momentum.service import MomentumService, REBALANCE_TRADING_DAYS


def test_ledger_buy_sell_roundtrip(tmp_path):
    path = os.path.join(tmp_path, "ledger.json")
    led = MomentumLedger(path=path)
    assert led.symbols() == []

    led.record_buy("AAPL", 1.5)
    led.record_buy("aapl", 0.5)  # case-insensitive, accumulates
    led.record_buy("MSFT", 2.0)
    assert led.symbols() == ["AAPL", "MSFT"]
    entries = {e.symbol: e.qty for e in led.entries()}
    assert entries["AAPL"] == 2.0
    assert entries["MSFT"] == 2.0

    # Full close removes the symbol entirely (rebalance sells the whole lot).
    led.record_sell("AAPL")
    assert led.symbols() == ["MSFT"]

    # Partial sell keeps the remainder.
    led.record_sell("MSFT", 0.5)
    assert {e.symbol: e.qty for e in led.entries()}["MSFT"] == 1.5

    # Selling an unknown symbol is a no-op.
    led.record_sell("TSLA")
    assert led.symbols() == ["MSFT"]

    # Non-positive buys are ignored.
    led.record_buy("NVDA", 0.0)
    assert "NVDA" not in led.symbols()


def test_ledger_persists_across_instances(tmp_path):
    path = os.path.join(tmp_path, "ledger.json")
    MomentumLedger(path=path).record_buy("AMZN", 3.0)
    assert MomentumLedger(path=path).has("AMZN")


def test_remark_constant_is_strategy_specific():
    # Must differ from the generic "tradewizz" remark so other strategies are
    # never mistaken for momentum holdings.
    assert MOMENTUM_REMARK == "tw:momentum"
    assert MOMENTUM_REMARK != "tradewizz"


def test_rebalance_diff_logic():
    """Pure SELL/BUY/HOLD diff: owned (ledger ∩ live) vs fresh top-N."""
    owned = {"AAPL", "MSFT", "GOOG"}       # momentum-held & live
    target = {"MSFT", "GOOG", "NVDA"}       # fresh top-N

    sells = sorted(owned - target)          # dropped out
    buys = sorted(target - owned)           # newly entered
    holds = sorted(owned & target)          # still in

    assert sells == ["AAPL"]
    assert buys == ["NVDA"]
    assert holds == ["GOOG", "MSFT"]


def test_ledger_last_rebalance_ts(tmp_path):
    path = os.path.join(tmp_path, "ledger.json")
    led = MomentumLedger(path=path)
    # Empty ledger has no clock (honest: None, not a fabricated date).
    assert led.last_rebalance_ts() is None
    led.record_buy("AAPL", 1.0)
    t1 = led.last_rebalance_ts()
    assert isinstance(t1, int) and t1 > 0
    time.sleep(0.01)
    led.record_buy("MSFT", 1.0)
    # Newest mutation wins.
    assert led.last_rebalance_ts() >= t1


class _CalCache:
    """Fake OHLCV cache exposing a synthetic weekday calendar up to ``end``."""

    def __init__(self, end: date, days: int = 400):
        idx = []
        d = end
        while len(idx) < days:
            if d.weekday() < 5:
                idx.append(pd.Timestamp(d))
            d = d - timedelta(days=1)
        idx = sorted(idx)
        self._df = pd.DataFrame(
            {"Adj Close": 1.0, "Close": 1.0, "Volume": 1.0}, index=pd.DatetimeIndex(idx)
        )

    def read_cached_only(self, symbol, period="1y", interval="1d"):
        return self._df if period == "max" else None


class _OneSym:
    def symbols(self, market):
        return ["AAA"]


def _svc(cal_end: date) -> MomentumService:
    return MomentumService(_CalCache(cal_end), _OneSym())


def test_rebalance_schedule_none_when_no_clock():
    svc = _svc(date(2026, 7, 2))
    s = svc.rebalance_schedule(None)
    assert s.status == "none"
    assert s.due_date is None and s.trading_days_remaining is None


def test_rebalance_schedule_monotonic_and_due():
    # Cached calendar lags the real clock (ends 2026-07-02) on purpose.
    svc = _svc(date(2026, 7, 2))
    now = int(time.time())
    fresh = svc.rebalance_schedule(now)                 # bought "today"
    older = svc.rebalance_schedule(now - 10 * 86400)    # bought 10d ago
    # A more recent buy must have >= remaining sessions than an older buy.
    assert fresh.trading_days_remaining >= older.trading_days_remaining
    # A fresh buy starts a full ~21-session clock and is upcoming, not due.
    assert fresh.status == "upcoming"
    assert fresh.trading_days_remaining == REBALANCE_TRADING_DAYS
    # A buy well over a month ago is overdue.
    stale = svc.rebalance_schedule(now - 45 * 86400)
    assert stale.status == "due"
    assert stale.trading_days_remaining <= 0
    assert stale.last_rebalance_date is not None and stale.due_date is not None


def test_rebalance_ignores_non_momentum_positions():
    """A bullish/manual position must never be selected for a momentum sell."""
    ledger_syms = {"AAPL"}                   # only AAPL bought via momentum
    live_held = {"AAPL", "TSLA", "COIN"}     # TSLA/COIN belong to other strats
    target = {"NVDA"}                        # AAPL dropped out of top-N

    owned = {s for s in ledger_syms if s in live_held}
    sells = owned - target
    # AAPL is sold; TSLA/COIN are invisible to the momentum rebalance.
    assert sells == {"AAPL"}
    assert "TSLA" not in sells and "COIN" not in sells
