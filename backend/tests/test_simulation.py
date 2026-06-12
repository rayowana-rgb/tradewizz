"""Simulated paper-trading portfolio: service + endpoints.

Covers every required behaviour: initial cash, buy creates position, second buy
updates average cost, sell reduces / removes, realized P/L, insufficient cash
and oversell rejection, all 9 markets accepted, reset, and the SAFETY guarantee
that NO broker code is ever invoked. Uses a fake price provider + in-memory
SQLite — no network, no broker.
"""

from __future__ import annotations

import pytest

from app import market_config
from app.models import Market
from app.simulation.models import (
    SIM_DISCLAIMER,
    SIM_FILL_MESSAGE,
    SIM_WARNING,
    STATUS_FILLED,
)
from app.simulation.service import (
    BASE_CURRENCY,
    SimulationError,
    SimulationService,
)
from app.simulation.store import SimulationStore

# The simulated cash ledger is kept in the base accounting currency (USD). A
# trade priced in USD therefore moves cash by ``value`` directly (fx==1); an
# IDX (Rupiah) trade moves cash by ``value / USD_FX``. ``_fx(market)`` mirrors
# the service's conversion so the tests assert deltas exactly as computed.
USD_FX = market_config.idr_per_unit(Market.US)   # IDR per 1 USD (≈16000)


def _fx(market):
    """Local-currency -> base(USD) multiplier, mirroring the service."""
    return market_config.idr_per_unit(market) / USD_FX


# A universe stub that accepts any symbol (universe validation is exercised
# separately); the real universe is also tested via test_global_markets.
class _AllSymbolsUniverse:
    def symbols(self, market):  # noqa: D401
        return []  # empty -> service does not block (graceful)


# Default simulated cash in the BASE currency (USD): one million US dollars.
DEFAULT_TEST_CASH = 1_000_000.0


def _make_service(prices=None, initial_cash=DEFAULT_TEST_CASH):
    prices = prices or {}

    def price_provider(symbol, market):
        return prices.get((symbol.upper(), market), 100.0)

    return SimulationService(
        price_provider=price_provider,
        store=SimulationStore(":memory:"),
        universe=_AllSymbolsUniverse(),
        initial_cash=initial_cash,
    )


UID = 1


# --------------------------------------------------------------------------- #
# Account                                                                     #
# --------------------------------------------------------------------------- #
def test_initial_account_has_simulated_cash():
    svc = _make_service(initial_cash=1_000_000.0)
    acct = svc.account(UID)
    assert acct.cash == 1_000_000.0
    assert acct.buying_power == 1_000_000.0
    assert acct.equity == 1_000_000.0
    assert acct.simulated is True
    assert acct.disclaimer == SIM_DISCLAIMER


def test_initial_cash_is_configurable():
    svc = _make_service(initial_cash=50_000.0)
    assert svc.account(UID).cash == 50_000.0


# --------------------------------------------------------------------------- #
# Buy                                                                         #
# --------------------------------------------------------------------------- #
def test_buy_creates_position_and_deducts_cash():
    svc = _make_service(prices={("AAPL", Market.US): 200.0})
    res = svc.place(UID, "AAPL", Market.US, "BUY", 10, "MARKET")
    assert res.status == STATUS_FILLED
    assert res.simulated is True
    assert res.message == SIM_FILL_MESSAGE
    assert res.price == 200.0
    assert res.value == 2000.0

    acct = svc.account(UID)
    # Cash is held in the base currency (USD): a $2000 buy debits $2000.
    assert acct.cash == pytest.approx(DEFAULT_TEST_CASH - 2000.0)
    assert acct.currency == BASE_CURRENCY
    pos = svc.positions(UID)
    assert len(pos) == 1
    assert pos[0].symbol == "AAPL"
    # The position keeps its LOCAL (USD) average cost untouched by FX.
    assert pos[0].average_cost == 200.0
    assert pos[0].quantity == 10
    assert pos[0].average_cost == 200.0


def test_second_buy_updates_average_cost():
    svc = _make_service(prices={("AAPL", Market.US): 100.0})
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)  # 10 @ 100
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 200.0)  # 10 @ 200
    pos = svc.positions(UID)[0]
    assert pos.quantity == 20
    assert pos.average_cost == pytest.approx(150.0)  # (1000+2000)/20


def test_buy_limit_uses_limit_price_market_uses_latest():
    svc = _make_service(prices={("AAPL", Market.US): 100.0})
    r_limit = svc.place(UID, "AAPL", Market.US, "BUY", 1, "LIMIT", 123.0)
    assert r_limit.price == 123.0
    r_market = svc.place(UID, "AAPL", Market.US, "BUY", 1, "MARKET")
    assert r_market.price == 100.0


# --------------------------------------------------------------------------- #
# Sell                                                                        #
# --------------------------------------------------------------------------- #
def test_sell_reduces_position():
    svc = _make_service(prices={("AAPL", Market.US): 100.0})
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)
    svc.place(UID, "AAPL", Market.US, "SELL", 4, "LIMIT", 120.0)
    pos = svc.positions(UID)[0]
    assert pos.quantity == 6


def test_sell_all_removes_position():
    svc = _make_service(prices={("AAPL", Market.US): 100.0})
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)
    svc.place(UID, "AAPL", Market.US, "SELL", 10, "LIMIT", 110.0)
    assert svc.positions(UID) == []


def test_realized_pnl_calculated_correctly():
    svc = _make_service()
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)   # cost 100
    res = svc.place(UID, "AAPL", Market.US, "SELL", 10, "LIMIT", 130.0)
    # (130 - 100) * 10 = 300 realized in LOCAL (USD) currency on the trade.
    assert res.realized_pnl == pytest.approx(300.0)
    acct = svc.account(UID)
    # The account ledger books realized P/L in the base currency (USD): $300.
    assert acct.realized_pnl == pytest.approx(300.0)
    # Cash: start - (1000 buy) + (1300 sell), all in base USD.
    assert acct.cash == pytest.approx(
        DEFAULT_TEST_CASH + (1300.0 - 1000.0)
    )


def test_partial_sell_keeps_average_cost_and_books_partial_pnl():
    svc = _make_service()
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)
    res = svc.place(UID, "AAPL", Market.US, "SELL", 4, "LIMIT", 150.0)
    assert res.realized_pnl == pytest.approx(200.0)  # (150-100)*4
    pos = svc.positions(UID)[0]
    assert pos.quantity == 6
    assert pos.average_cost == pytest.approx(100.0)  # avg unchanged on sell
    assert pos.realized_pnl == pytest.approx(200.0)


# --------------------------------------------------------------------------- #
# Validation                                                                  #
# --------------------------------------------------------------------------- #
def test_insufficient_cash_rejected():
    svc = _make_service(prices={("AAPL", Market.US): 100.0}, initial_cash=500.0)
    with pytest.raises(SimulationError) as ei:
        svc.place(UID, "AAPL", Market.US, "BUY", 100, "LIMIT", 100.0)
    assert "cash" in ei.value.message.lower()


def test_selling_more_than_held_rejected():
    svc = _make_service()
    svc.place(UID, "AAPL", Market.US, "BUY", 5, "LIMIT", 100.0)
    with pytest.raises(SimulationError) as ei:
        svc.place(UID, "AAPL", Market.US, "SELL", 6, "LIMIT", 100.0)
    assert "more than" in ei.value.message.lower()


def test_sell_without_position_rejected():
    svc = _make_service()
    with pytest.raises(SimulationError):
        svc.place(UID, "AAPL", Market.US, "SELL", 1, "LIMIT", 100.0)


def test_unknown_symbol_rejected_when_universe_known():
    class KnownUniverse:
        def symbols(self, market):
            return ["AAPL"]

    svc = SimulationService(
        price_provider=lambda s, m: 100.0,
        store=SimulationStore(":memory:"),
        universe=KnownUniverse(),
    )
    with pytest.raises(SimulationError) as ei:
        svc.place(UID, "ZZZZ", Market.US, "BUY", 1, "LIMIT", 100.0)
    assert ei.value.status_code == 404


# --------------------------------------------------------------------------- #
# All markets                                                                 #
# --------------------------------------------------------------------------- #
ALL_MARKET_CASES = [
    ("AAPL", Market.US),
    ("0700", Market.HKEX),
    ("7203", Market.JAPAN),
    ("RELIANCE", Market.INDIA),
    ("VCB", Market.VIETNAM),
    ("D05", Market.SINGAPORE),
    ("BBCA", Market.IDX),
    ("005930", Market.KOSPI),
    ("035720", Market.KOSDAQ),
]


@pytest.mark.parametrize("symbol,market", ALL_MARKET_CASES)
def test_all_markets_accepted(symbol, market):
    svc = _make_service()
    res = svc.place(UID, symbol, market, "BUY", 1, "LIMIT", 50.0)
    assert res.status == STATUS_FILLED
    assert res.market == market
    assert res.simulated is True
    pos = svc.positions(UID)
    assert any(p.symbol == symbol.upper() and p.market == market for p in pos)


# --------------------------------------------------------------------------- #
# Preview                                                                     #
# --------------------------------------------------------------------------- #
def test_preview_does_not_mutate_and_is_marked_simulated():
    svc = _make_service(prices={("AAPL", Market.US): 100.0})
    pv = svc.preview(UID, "AAPL", Market.US, "BUY", 10, "MARKET")
    assert pv.simulated is True
    assert pv.warning == SIM_WARNING
    # Estimated value is shown in the stock's LOCAL (USD) currency on the ticket.
    assert pv.estimated_value == 1000.0
    assert pv.currency == "USD"
    assert pv.price == 100.0
    # Cash-after is in the base currency (USD): 1,000,000 - 1000.
    assert pv.cash_after == pytest.approx(DEFAULT_TEST_CASH - 1000.0)
    # No position created by a preview.
    assert svc.positions(UID) == []
    assert svc.account(UID).cash == DEFAULT_TEST_CASH


def test_preview_rejects_insufficient_cash():
    svc = _make_service(initial_cash=100.0)
    with pytest.raises(SimulationError):
        svc.preview(UID, "AAPL", Market.US, "BUY", 100, "LIMIT", 100.0)


# --------------------------------------------------------------------------- #
# Reset                                                                       #
# --------------------------------------------------------------------------- #
def test_reset_clears_positions_trades_and_restores_cash():
    svc = _make_service(initial_cash=DEFAULT_TEST_CASH)
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)
    svc.place(UID, "AAPL", Market.US, "SELL", 5, "LIMIT", 120.0)
    assert svc.positions(UID)
    assert svc.trades(UID)

    acct = svc.reset(UID)
    assert acct.cash == DEFAULT_TEST_CASH
    assert acct.realized_pnl == 0.0
    assert svc.positions(UID) == []
    assert svc.trades(UID) == []


# --------------------------------------------------------------------------- #
# Trades log                                                                  #
# --------------------------------------------------------------------------- #
def test_trades_recorded_for_buy_and_sell():
    svc = _make_service()
    svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 100.0)
    svc.place(UID, "AAPL", Market.US, "SELL", 5, "LIMIT", 110.0)
    trades = svc.trades(UID)
    assert len(trades) == 2
    assert {t.side for t in trades} == {"BUY", "SELL"}
    assert all(t.simulated for t in trades)


# --------------------------------------------------------------------------- #
# SAFETY: no broker code is touched                                           #
# --------------------------------------------------------------------------- #
def test_simulation_source_imports_no_broker_packages():
    import ast
    import importlib

    # Parse each simulation module's imports: none may reference broker/brokers,
    # ibkr or moomoo. (Docstrings mentioning 'broker' are fine; we inspect the
    # actual import statements, not free text.)
    for name in ("models", "store", "service", "router"):
        mod = importlib.import_module(f"app.simulation.{name}")
        with open(mod.__file__) as f:
            tree = ast.parse(f.read())
        imported = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported += [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                imported.append(node.module or "")
        joined = " ".join(imported).lower()
        assert "broker" not in joined, f"{name} imports a broker module"
        assert "ibkr" not in joined
        assert "moomoo" not in joined


def test_place_never_calls_broker(monkeypatch):
    # If any broker adapter were invoked it would raise; the simulated path must
    # complete without touching it.
    import app.brokers.adapter as adapter

    def _boom(*a, **k):
        raise AssertionError("broker adapter must not be called in simulation")

    monkeypatch.setattr(adapter, "make_adapter", _boom)
    svc = _make_service()
    res = svc.place(UID, "AAPL", Market.US, "BUY", 1, "LIMIT", 100.0)
    assert res.status == STATUS_FILLED
