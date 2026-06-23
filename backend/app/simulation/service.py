"""Simulated paper-trading service.

Pure local simulation: validates symbol/market against the universe, fetches the
latest price from the existing analysis/fetch engine (price lookup only), and
mutates a per-user SQLite portfolio. NEVER calls a broker, NEVER places a real
order. Average cost uses a weighted-average model; realized P/L is booked on
SELL against average cost.
"""

from __future__ import annotations

import os
import uuid
from datetime import datetime, timezone
from typing import Callable, List, Optional

from .. import market_config
from ..market_session import (
    MarketSessionState,
    get_market_session_state,
    trading_date_str,
)
from ..models import Market
from ..universe import UniverseRepository
from .models import (
    SIM_CANCEL_MESSAGE,
    SIM_FILL_MESSAGE,
    SIM_PENDING_MESSAGE,
    SIM_WARNING,
    STATUS_CANCELLED,
    STATUS_FILLED,
    STATUS_PENDING,
    SimulatedAccount,
    SimulatedCancelResult,
    SimulatedOrderPreview,
    SimulatedOrderResult,
    SimulatedPendingOrder,
    SimulatedPortfolioSummary,
    SimulatedPosition,
    SimulatedTrade,
)
from .store import AccountRow, PendingOrderRow, PositionRow, SimulationStore

# Resolves the OPEN price of the first cached bar strictly after a trading date.
# Returns (open_price, bar_date) or None. Injected so the service stays testable
# without the real OHLCV cache.
OpenPriceProvider = Callable[[str, Market, str], Optional[tuple]]
# Classifies a market's current session state (OPEN / CLOSED / ...). Injected
# so tests can force a closed market deterministically.
SessionStateProvider = Callable[[Market], MarketSessionState]

# Base accounting currency for the simulated portfolio. Every cross-market
# aggregate (cash, equity, market value, P/L) is held in this currency so a
# Rupiah (IDX) position and a US-dollar position can be summed correctly. Per
# the user's preference this is USD; positions still keep their LOCAL
# price/avg-cost so each row reads naturally in its own currency, while cash is
# debited/credited in USD using an FX conversion at the time of the trade.
BASE_CURRENCY = os.environ.get("TRADEWIZZ_SIM_BASE_CURRENCY", "USD")

# Default starting cash, expressed in the base currency. Default: $1,000,000
# (one million US dollars) of simulated buying power.
DEFAULT_INITIAL_CASH = float(
    os.environ.get("TRADEWIZZ_SIM_INITIAL_CASH", "1000000")
)

# A price provider takes (symbol, market) and returns the latest price or None.
PriceProvider = Callable[[str, Market], Optional[float]]


def _base_idr_per_unit() -> float:
    """IDR value of 1 unit of the BASE_CURRENCY (e.g. ~16000 for USD, 1 for IDR).

    Resolved by finding any configured market whose currency matches
    BASE_CURRENCY and reading its ``idr_per_unit``. Falls back to 1.0 so an
    unknown base degrades to an IDR-style (no-op) conversion.
    """
    if BASE_CURRENCY == "IDR":
        return 1.0
    for mkt in Market:
        try:
            if market_config.currency(mkt) == BASE_CURRENCY:
                rate = market_config.idr_per_unit(mkt)
                if rate > 0:
                    return rate
        except Exception:  # noqa: BLE001
            continue
    return 1.0


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class SimulationError(Exception):
    """Validation failure mapped to an HTTP error by the router."""

    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class SimulationService:
    def __init__(
        self,
        price_provider: PriceProvider,
        store: Optional[SimulationStore] = None,
        universe: Optional[UniverseRepository] = None,
        initial_cash: float = DEFAULT_INITIAL_CASH,
        open_price_provider: Optional[OpenPriceProvider] = None,
        session_state_provider: Optional[SessionStateProvider] = None,
    ):
        self._price = price_provider
        self._store = store or SimulationStore()
        self._universe = universe or UniverseRepository()
        self._initial_cash = initial_cash
        # Used to settle a pending (closed-market) order at the next open.
        self._open_price = open_price_provider
        # Defaults to the real wall-clock session classifier.
        self._session_state = session_state_provider or get_market_session_state

    # -- helpers ---------------------------------------------------------
    def _validate_symbol(self, symbol: str, market: Market) -> str:
        """Ensure the symbol exists in the market's universe; return canonical.

        Universes store bare symbols (suffix stripped). We compare case-insens.
        If a universe file is missing/empty we DO NOT block the simulation
        (graceful) — the price lookup is the ultimate gate.
        """
        sym = symbol.strip().upper()
        if not sym:
            raise SimulationError("Symbol is required.")
        try:
            known = {s.upper() for s in self._universe.symbols(market)}
        except Exception:  # noqa: BLE001 - universe is best-effort
            known = set()
        if known and sym not in known:
            raise SimulationError(
                f"{sym} is not a known {market.value} symbol.", 404
            )
        return sym

    def _exec_price(
        self, symbol: str, market: Market, order_type: str, price: Optional[float]
    ) -> float:
        """Resolve the simulated execution price.

        LIMIT with a price -> use that price. Otherwise use the latest close.
        """
        if order_type.upper() == "LIMIT" and price is not None and price > 0:
            return float(price)
        last = self._price(symbol, market)
        if last is None or last <= 0:
            raise SimulationError(
                f"No price available for {symbol} on {market.value}.", 502
            )
        return float(last)

    def _currency(self, market: Market) -> str:
        try:
            return market_config.currency(market)
        except Exception:  # noqa: BLE001
            return "USD"

    def _account(self, user_id: int) -> AccountRow:
        """Fetch the account, migrating stale (pre-base-currency) rows once.

        Accounts created before the base-currency fix carry a non-base currency
        (e.g. "USD") and a balance that had been mixed with Rupiah-priced
        orders. The first time we see one, reset it to a clean base-currency
        ledger so cash / equity / P/L are coherent. New accounts are created
        directly in the base currency and skip this path.
        """
        acct = self._store.get_or_create_account(
            user_id, self._initial_cash, BASE_CURRENCY
        )
        if acct.currency != BASE_CURRENCY:
            self._store.reset(user_id, self._initial_cash, BASE_CURRENCY)
            acct = self._store.get_or_create_account(
                user_id, self._initial_cash, BASE_CURRENCY
            )
        return acct

    def _fx_to_base(self, market: Market) -> float:
        """Multiplier converting 1 unit of the market's currency into the base
        accounting currency.

        ``idr_per_unit`` expresses "how many IDR is 1 unit of this market's
        currency" (IDX=1, USD≈16000, ...). We convert any market's local
        currency into the base by going through IDR::

            fx_to_base(market) = idr_per_unit(market) / idr_per_unit(base)

        With the USD base this yields IDX=1/16000 (≈$0.0000625 per Rupiah) and
        US=1.0. With an IDR base it collapses to idr_per_unit(market).
        """
        try:
            per_unit_idr = market_config.idr_per_unit(market)
        except Exception:  # noqa: BLE001
            per_unit_idr = 1.0
        base_idr = _base_idr_per_unit()
        if base_idr <= 0:
            return per_unit_idr
        return per_unit_idr / base_idr

    # -- pending-order helpers -------------------------------------------
    def _market_open(self, market: Market) -> bool:
        """True when the market's regular session is currently OPEN.

        A simulated MARKET order is filled immediately while OPEN; when the
        market is in any non-OPEN state (CLOSED / PRE / POST) a MARKET order is
        queued to execute at the next session's open price.
        """
        try:
            return self._session_state(market) is MarketSessionState.OPEN
        except Exception:  # noqa: BLE001 - best-effort; default to closed-safe
            return False

    def _reserved_cash(self, user_id: int) -> float:
        """Total base-currency cash set aside by this user's pending BUY orders."""
        total = 0.0
        for p in self._store.list_pending_orders(user_id, "PENDING"):
            if p.side == "BUY":
                total += p.reserved_cash_base
        return total

    def _pending_model(self, row: PendingOrderRow) -> SimulatedPendingOrder:
        return SimulatedPendingOrder(
            order_id=row.order_id,
            symbol=row.symbol,
            market=Market(row.market),
            side=row.side,
            quantity=round(row.quantity, 6),
            order_type=row.order_type,
            limit_price=(
                round(row.limit_price, 6) if row.limit_price else None
            ),
            reserved_cash=round(row.reserved_cash_base, 2),
            placed_trading_date=row.placed_trading_date,
            status=STATUS_PENDING,
            placed_at=row.placed_at,
        )

    # -- account / portfolio ---------------------------------------------
    def _account_model(
        self, user_id: int, positions: List[SimulatedPosition]
    ) -> SimulatedAccount:
        acct: AccountRow = self._account(user_id)
        # Cash and realized P/L are already stored in the base currency. Each
        # position's market_value / unrealized_pnl are in its LOCAL currency, so
        # convert them to base before summing across markets.
        market_value = sum(
            p.market_value * self._fx_to_base(p.market) for p in positions
        )
        unrealized = sum(
            p.unrealized_pnl * self._fx_to_base(p.market) for p in positions
        )
        equity = acct.cash + market_value
        # Cash reserved by pending BUYs is still part of ``cash`` (only debited
        # at fill) but is NOT available buying power.
        pendings = self._store.list_pending_orders(user_id, "PENDING")
        reserved = sum(
            p.reserved_cash_base for p in pendings if p.side == "BUY"
        )
        return SimulatedAccount(
            user_id=user_id,
            cash=round(acct.cash, 2),
            equity=round(equity, 2),
            buying_power=round(max(acct.cash - reserved, 0.0), 2),
            market_value=round(market_value, 2),
            unrealized_pnl=round(unrealized, 2),
            realized_pnl=round(acct.realized_pnl, 2),
            reserved_cash=round(reserved, 2),
            pending_orders=len(pendings),
            currency=BASE_CURRENCY,
            created_at=acct.created_at,
            updated_at=acct.updated_at,
        )

    def _position_model(self, row: PositionRow) -> SimulatedPosition:
        market = Market(row.market)
        last = self._price(row.symbol, market)
        last_price = float(last) if last and last > 0 else row.average_cost
        market_value = row.quantity * last_price
        unrealized = (last_price - row.average_cost) * row.quantity
        return SimulatedPosition(
            user_id=row.user_id,
            symbol=row.symbol,
            market=market,
            quantity=round(row.quantity, 6),
            average_cost=round(row.average_cost, 6),
            last_price=round(last_price, 6),
            market_value=round(market_value, 2),
            unrealized_pnl=round(unrealized, 2),
            realized_pnl=round(row.realized_pnl, 2),
            created_at=row.created_at,
            updated_at=row.updated_at,
        )

    def positions(self, user_id: int) -> List[SimulatedPosition]:
        # Run the stale-account migration FIRST (it may clear positions) so every
        # consumer of positions() -- AI Portfolio Manager, Rebalancing, Health --
        # sees the same post-migration holdings as the Portfolio page. Without
        # this, a stale pre-base-currency account would show phantom positions in
        # those features even though portfolio() had already wiped them.
        self._account(user_id)
        # Best-effort: fill any pending (closed-market) orders whose next-open
        # bar is now available, so holdings/P&L reflect settled trades.
        self._settle_pending(user_id)
        return [self._position_model(r) for r in self._store.list_positions(user_id)]

    def account(self, user_id: int) -> SimulatedAccount:
        # Migrate stale accounts first (may clear positions) before snapshotting.
        self._account(user_id)
        return self._account_model(user_id, self.positions(user_id))

    def portfolio(self, user_id: int) -> SimulatedPortfolioSummary:
        # Migrate stale accounts first so positions reflect the post-reset state.
        self._account(user_id)
        positions = self.positions(user_id)
        account = self._account_model(user_id, positions)
        pending = [
            self._pending_model(p)
            for p in self._store.list_pending_orders(user_id, "PENDING")
        ]
        return SimulatedPortfolioSummary(
            account=account, positions=positions, pending=pending
        )

    def pending(self, user_id: int) -> List[SimulatedPendingOrder]:
        self._account(user_id)
        self._settle_pending(user_id)
        return [
            self._pending_model(p)
            for p in self._store.list_pending_orders(user_id, "PENDING")
        ]

    def trades(self, user_id: int, limit: int = 200) -> List[SimulatedTrade]:
        out: List[SimulatedTrade] = []
        for t in self._store.list_trades(user_id, limit):
            out.append(
                SimulatedTrade(
                    id=t.id, user_id=t.user_id, order_id=t.order_id,
                    symbol=t.symbol, market=Market(t.market), side=t.side,
                    quantity=round(t.quantity, 6), price=round(t.price, 6),
                    value=round(t.value, 2),
                    realized_pnl=round(t.realized_pnl, 2),
                    created_at=t.created_at,
                )
            )
        return out

    # -- order flow ------------------------------------------------------
    def preview(
        self,
        user_id: int,
        symbol: str,
        market: Market,
        side: str,
        quantity: float,
        order_type: str = "MARKET",
        price: Optional[float] = None,
    ) -> SimulatedOrderPreview:
        side = side.upper()
        if side not in ("BUY", "SELL"):
            raise SimulationError("side must be BUY or SELL.")
        if quantity <= 0:
            raise SimulationError("Quantity must be positive.")
        sym = self._validate_symbol(symbol, market)
        exec_price = self._exec_price(sym, market, order_type, price)
        # Value in the stock's LOCAL currency (what the user sees on the ticket).
        est_value = quantity * exec_price
        # Value converted to the base accounting currency for the cash ledger.
        fx = self._fx_to_base(market)
        est_value_base = est_value * fx
        acct = self._account(user_id)

        if side == "BUY":
            if est_value_base > acct.cash + 1e-9:
                raise SimulationError(
                    "Insufficient simulated cash for this order.", 400
                )
            cash_after = acct.cash - est_value_base
        else:  # SELL
            pos = self._store.get_position(user_id, sym, market.value)
            held = pos.quantity if pos else 0.0
            if quantity > held + 1e-9:
                raise SimulationError(
                    "Cannot sell more than the simulated quantity held.", 400
                )
            cash_after = acct.cash + est_value_base

        return SimulatedOrderPreview(
            symbol=sym,
            market=market,
            side=side,
            quantity=quantity,
            order_type=order_type.upper(),
            price=round(exec_price, 6),
            estimated_value=round(est_value, 2),
            currency=self._currency(market),
            cash_after=round(cash_after, 2),
            warning=SIM_WARNING,
        )

    def place(
        self,
        user_id: int,
        symbol: str,
        market: Market,
        side: str,
        quantity: float,
        order_type: str = "MARKET",
        price: Optional[float] = None,
    ) -> SimulatedOrderResult:
        side = side.upper()
        if side not in ("BUY", "SELL"):
            raise SimulationError("side must be BUY or SELL.")
        if quantity <= 0:
            raise SimulationError("Quantity must be positive.")
        sym = self._validate_symbol(symbol, market)
        otype = order_type.upper()

        # Settle any already-fillable pending orders first so accounting below
        # (held quantity, reserved cash) reflects the latest state.
        self._settle_pending(user_id)

        # A MARKET order placed while the market is NOT open is queued and will
        # execute at the next session's OPEN price. A LIMIT order (user supplies
        # the price) still fills immediately at that price -- there is no open
        # ambiguity. This avoids marking a brand-new position to a stale close
        # and miscomputing P/L until the real open prints.
        if otype == "MARKET" and not self._market_open(market):
            return self._queue_pending(user_id, sym, market, side, quantity)

        exec_price = self._exec_price(sym, market, otype, price)
        return self._execute_fill(
            user_id, sym, market, side, quantity, exec_price, otype
        )

    def _execute_fill(
        self,
        user_id: int,
        sym: str,
        market: Market,
        side: str,
        quantity: float,
        exec_price: float,
        order_type: str = "MARKET",
    ) -> SimulatedOrderResult:
        """Apply a fill at ``exec_price`` (shared by immediate + settled fills)."""
        # Trade value in the stock's LOCAL currency (logged as-is on the ticket).
        value = quantity * exec_price
        # FX factor into the base accounting currency for the cash ledger.
        fx = self._fx_to_base(market)
        value_base = value * fx
        acct = self._account(user_id)
        pos = self._store.get_position(user_id, sym, market.value)

        realized = 0.0          # in LOCAL currency (for the trade log)
        realized_base = 0.0     # in BASE currency (for the account ledger)
        if side == "BUY":
            if value_base > acct.cash + 1e-9:
                raise SimulationError(
                    "Insufficient simulated cash for this order.", 400
                )
            held = pos.quantity if pos else 0.0
            prev_avg = pos.average_cost if pos else 0.0
            prev_realized = pos.realized_pnl if pos else 0.0
            new_qty = held + quantity
            new_avg = (
                (held * prev_avg + quantity * exec_price) / new_qty
                if new_qty > 0
                else exec_price
            )
            self._store.upsert_position(
                user_id, sym, market.value, new_qty, new_avg, prev_realized
            )
            new_cash = acct.cash - value_base
        else:  # SELL
            held = pos.quantity if pos else 0.0
            if quantity > held + 1e-9:
                raise SimulationError(
                    "Cannot sell more than the simulated quantity held.", 400
                )
            avg = pos.average_cost if pos else 0.0
            realized = (exec_price - avg) * quantity      # local currency
            realized_base = realized * fx                 # base currency
            remaining = held - quantity
            new_realized = (pos.realized_pnl if pos else 0.0) + realized
            if remaining <= 1e-9:
                self._store.delete_position(user_id, sym, market.value)
            else:
                self._store.upsert_position(
                    user_id, sym, market.value, remaining, avg, new_realized
                )
            new_cash = acct.cash + value_base

        new_account_realized = acct.realized_pnl + realized_base
        self._store.update_account(user_id, new_cash, new_account_realized)

        order_id = "SIM-" + uuid.uuid4().hex[:12].upper()
        self._store.add_trade(
            user_id, order_id, sym, market.value, side, quantity,
            exec_price, value, realized,
        )
        return SimulatedOrderResult(
            order_id=order_id,
            symbol=sym,
            market=market,
            side=side,
            quantity=quantity,
            price=round(exec_price, 6),
            value=round(value, 2),
            status=STATUS_FILLED,
            realized_pnl=round(realized, 2),
            cash_after=round(new_cash, 2),
            message=SIM_FILL_MESSAGE,
        )

    def _queue_pending(
        self,
        user_id: int,
        sym: str,
        market: Market,
        side: str,
        quantity: float,
    ) -> SimulatedOrderResult:
        """Queue a MARKET order placed while the market is closed.

        BUY: reserve an ESTIMATE of the cash (qty * latest cached close * fx)
        against available buying power so it can't be double-committed; the real
        debit happens at the open fill. SELL: ensure the user holds enough
        (minus any quantity already promised to other pending sells).
        """
        acct = self._account(user_id)
        fx = self._fx_to_base(market)
        # Best-effort estimate price for the ticket / reservation (latest close).
        est_price = self._price(sym, market)
        est_local = (quantity * est_price) if est_price and est_price > 0 else 0.0
        est_base = est_local * fx

        if side == "BUY":
            available = acct.cash - self._reserved_cash(user_id)
            if est_base > available + 1e-9:
                raise SimulationError(
                    "Insufficient simulated cash for this order.", 400
                )
        else:  # SELL
            pos = self._store.get_position(user_id, sym, market.value)
            held = pos.quantity if pos else 0.0
            already_pending = sum(
                p.quantity
                for p in self._store.list_pending_orders(user_id, "PENDING")
                if p.side == "SELL"
                and p.symbol == sym
                and p.market == market.value
            )
            if quantity > held - already_pending + 1e-9:
                raise SimulationError(
                    "Cannot sell more than the simulated quantity held.", 400
                )

        order_id = "SIM-" + uuid.uuid4().hex[:12].upper()
        placed_date = trading_date_str(market)
        self._store.add_pending_order(
            user_id, order_id, sym, market.value, side, quantity,
            "MARKET", None, est_base if side == "BUY" else 0.0, placed_date,
        )
        return SimulatedOrderResult(
            order_id=order_id,
            symbol=sym,
            market=market,
            side=side,
            quantity=quantity,
            price=round(est_price, 6) if est_price else 0.0,
            value=round(est_local, 2),
            status=STATUS_PENDING,
            realized_pnl=0.0,
            cash_after=round(acct.cash, 2),
            pending=True,
            message=SIM_PENDING_MESSAGE,
        )

    def _settle_pending(self, user_id: int) -> int:
        """Fill any pending orders whose next-session OPEN bar is now cached.

        Returns the number of orders settled. Best-effort and idempotent: an
        order only fills once its OPEN price for a date AFTER its placed trading
        date is available; otherwise it stays pending. Any per-order failure is
        isolated so one bad order can't block the rest.
        """
        if self._open_price is None:
            return 0
        settled = 0
        for p in self._store.list_pending_orders(user_id, "PENDING"):
            try:
                market = Market(p.market)
                resolved = self._open_price(
                    p.symbol, market, p.placed_trading_date
                )
                if not resolved:
                    continue
                open_price, _bar_date = resolved
                if not open_price or open_price <= 0:
                    continue
                # Mark the pending order done BEFORE filling so its reserved
                # cash is released from the buying-power calc inside the fill.
                self._store.set_pending_status(p.id, "FILLED")
                try:
                    self._execute_fill(
                        user_id, p.symbol, market, p.side, p.quantity,
                        float(open_price), "MARKET",
                    )
                    settled += 1
                except SimulationError:
                    # Fill no longer valid (e.g. insufficient cash after other
                    # activity, or position sold elsewhere): drop the order.
                    self._store.set_pending_status(p.id, "REJECTED")
            except Exception:  # noqa: BLE001 - one bad order must not block others
                continue
        return settled

    def cancel(self, user_id: int, order_id: str) -> SimulatedCancelResult:
        """Cancel a still-pending simulated order (releases any reserved cash)."""
        self._account(user_id)
        row = self._store.get_pending_order(user_id, order_id)
        if row is None or row.status != "PENDING":
            raise SimulationError("No pending simulated order with that id.", 404)
        self._store.set_pending_status(row.id, "CANCELLED")
        acct = self._account(user_id)
        return SimulatedCancelResult(
            order_id=order_id,
            status=STATUS_CANCELLED,
            cash_after=round(acct.cash, 2),
            message=SIM_CANCEL_MESSAGE,
        )

    def reset(self, user_id: int) -> SimulatedAccount:
        self._store.reset(user_id, self._initial_cash, BASE_CURRENCY)
        return self.account(user_id)
