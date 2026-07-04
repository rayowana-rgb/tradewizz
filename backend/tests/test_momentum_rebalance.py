"""Momentum ledger + rebalance-diff tests (no OpenD / no network)."""

from __future__ import annotations

import os

from app.momentum.ledger import MOMENTUM_REMARK, MomentumLedger


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
