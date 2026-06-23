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
from app.market_session import MarketSessionState
from app.simulation.models import (
    SIM_DISCLAIMER,
    SIM_FILL_MESSAGE,
    SIM_WARNING,
    STATUS_CANCELLED,
    STATUS_FILLED,
    STATUS_PENDING,
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


def _make_service(
    prices=None,
    initial_cash=DEFAULT_TEST_CASH,
    session_state=MarketSessionState.OPEN,
    open_prices=None,
):
    """Build a service. Defaults to an OPEN market so MARKET orders fill
    immediately (the long-standing behaviour these tests assert). Pass a
    different ``session_state`` (e.g. CLOSED) and ``open_prices`` to exercise
    the pending / next-open-settlement path.
    """
    prices = prices or {}
    open_prices = open_prices or {}

    def price_provider(symbol, market):
        return prices.get((symbol.upper(), market), 100.0)

    def open_price_provider(symbol, market, after_date):
        key = (symbol.upper(), market)
        if key in open_prices:
            return (open_prices[key], "2026-01-02")
        return None

    return SimulationService(
        price_provider=price_provider,
        store=SimulationStore(":memory:"),
        universe=_AllSymbolsUniverse(),
        initial_cash=initial_cash,
        open_price_provider=open_price_provider,
        session_state_provider=lambda m: session_state,
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
def test_positions_consistent_with_portfolio_for_stale_account():
    """A stale pre-base-currency account is migrated (positions wiped) the first
    time it is read. positions() must apply the SAME migration as portfolio(),
    so the AI Portfolio Manager / Rebalancing / Health never show phantom
    holdings that the Portfolio page has already cleared.
    """
    svc = _make_service(initial_cash=DEFAULT_TEST_CASH)
    store = svc._store
    # Seed a stale account (non-base currency) with a leftover position, exactly
    # like an account created before the base-currency fix.
    store.get_or_create_account(UID, DEFAULT_TEST_CASH, "JPY")
    store.upsert_position(UID, "AAPL", Market.US.value, 10, 100.0, 0.0)
    assert store.list_positions(UID)  # raw store still holds the stale row

    # Both consumers must agree: migration clears the stale holdings.
    assert svc.positions(UID) == []
    assert svc.portfolio(UID).positions == []


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


# --------------------------------------------------------------------------- #
# Pending orders: MARKET order while the market is CLOSED queues and settles    #
# at the next session's OPEN price (so held-position P/L is never computed off  #
# a stale close).                                                              #
# --------------------------------------------------------------------------- #
def test_closed_market_buy_is_pending_not_filled():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.CLOSED,
    )
    res = svc.place(UID, "AAPL", Market.US, "BUY", 10)
    assert res.status == STATUS_PENDING
    assert res.pending is True
    # No position yet, cash untouched (only reserved).
    assert svc.positions(UID) == []
    acct = svc.account(UID)
    assert acct.cash == pytest.approx(DEFAULT_TEST_CASH)
    # Buying power is reduced by the reserved estimate (10 * 200 = 2000).
    assert acct.reserved_cash == pytest.approx(2000.0)
    assert acct.buying_power == pytest.approx(DEFAULT_TEST_CASH - 2000.0)
    assert acct.pending_orders == 1


def test_open_market_buy_fills_immediately():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.OPEN,
    )
    res = svc.place(UID, "AAPL", Market.US, "BUY", 10)
    assert res.status == STATUS_FILLED
    assert res.pending is False
    pos = svc.positions(UID)
    assert len(pos) == 1 and pos[0].quantity == 10


def test_pending_buy_settles_at_open_price():
    # Placed close price 200, but the NEXT OPEN prints 210 -> fill at 210.
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        open_prices={("AAPL", Market.US): 210.0},
        session_state=MarketSessionState.CLOSED,
    )
    svc.place(UID, "AAPL", Market.US, "BUY", 10)
    # Settlement happens lazily on read.
    pos = svc.positions(UID)
    assert len(pos) == 1
    assert pos[0].average_cost == pytest.approx(210.0)  # OPEN price, not 200
    acct = svc.account(UID)
    # Cash debited by the REAL open value (10 * 210 = 2100), reserve released.
    assert acct.cash == pytest.approx(DEFAULT_TEST_CASH - 2100.0)
    assert acct.reserved_cash == pytest.approx(0.0)
    assert acct.pending_orders == 0


def test_pending_buy_stays_pending_until_open_available():
    # No open price yet -> order remains pending across reads.
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        open_prices={},  # provider returns None
        session_state=MarketSessionState.CLOSED,
    )
    svc.place(UID, "AAPL", Market.US, "BUY", 10)
    assert svc.positions(UID) == []
    assert svc.account(UID).pending_orders == 1


def test_closed_market_sell_pends_and_settles_at_open():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        open_prices={("AAPL", Market.US): 220.0},
        session_state=MarketSessionState.OPEN,
    )
    # Buy 10 @200 while open.
    svc.place(UID, "AAPL", Market.US, "BUY", 10)
    # Now go closed and queue a sell.
    svc._session_state = lambda m: MarketSessionState.CLOSED
    res = svc.place(UID, "AAPL", Market.US, "SELL", 5)
    assert res.status == STATUS_PENDING
    # Position still 10 until settled.
    assert svc._store.get_position(UID, "AAPL", "US").quantity == 10
    # Settle at open 220: realized (220-200)*5 = 100.
    pos = svc.positions(UID)
    assert pos[0].quantity == 5
    assert svc.account(UID).realized_pnl == pytest.approx(100.0)


def test_pending_sell_cannot_exceed_held_including_other_pending():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.OPEN,
    )
    svc.place(UID, "AAPL", Market.US, "BUY", 10)
    svc._session_state = lambda m: MarketSessionState.CLOSED
    svc.place(UID, "AAPL", Market.US, "SELL", 7)
    with pytest.raises(SimulationError):
        svc.place(UID, "AAPL", Market.US, "SELL", 5)  # 7+5 > 10


def test_pending_buy_rejected_when_reserve_exceeds_cash():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.CLOSED,
        initial_cash=1500.0,
    )
    with pytest.raises(SimulationError):
        svc.place(UID, "AAPL", Market.US, "BUY", 10)  # 2000 > 1500


def test_cancel_pending_releases_reserve():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.CLOSED,
    )
    res = svc.place(UID, "AAPL", Market.US, "BUY", 10)
    assert svc.account(UID).reserved_cash == pytest.approx(2000.0)
    cancel = svc.cancel(UID, res.order_id)
    assert cancel.status == STATUS_CANCELLED
    acct = svc.account(UID)
    assert acct.reserved_cash == pytest.approx(0.0)
    assert acct.buying_power == pytest.approx(DEFAULT_TEST_CASH)
    assert acct.pending_orders == 0


def test_cancel_unknown_pending_rejected():
    svc = _make_service(session_state=MarketSessionState.CLOSED)
    with pytest.raises(SimulationError):
        svc.cancel(UID, "SIM-DOESNOTEXIST")


def test_limit_order_fills_immediately_even_when_closed():
    # A LIMIT order carries its own price -> no open ambiguity -> fills now.
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.CLOSED,
    )
    res = svc.place(UID, "AAPL", Market.US, "BUY", 10, "LIMIT", 199.0)
    assert res.status == STATUS_FILLED
    assert svc.positions(UID)[0].average_cost == pytest.approx(199.0)


def test_pending_orders_appear_in_portfolio_summary():
    svc = _make_service(
        prices={("AAPL", Market.US): 200.0},
        session_state=MarketSessionState.CLOSED,
    )
    svc.place(UID, "AAPL", Market.US, "BUY", 10)
    summary = svc.portfolio(UID)
    assert len(summary.pending) == 1
    assert summary.pending[0].side == "BUY"
    assert summary.pending[0].status == STATUS_PENDING
