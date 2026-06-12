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
from ..models import Market
from ..universe import UniverseRepository
from .models import (
    SIM_FILL_MESSAGE,
    SIM_WARNING,
    STATUS_FILLED,
    SimulatedAccount,
    SimulatedOrderPreview,
    SimulatedOrderResult,
    SimulatedPortfolioSummary,
    SimulatedPosition,
    SimulatedTrade,
)
from .store import AccountRow, PositionRow, SimulationStore

# Base accounting currency for the simulated portfolio. Every cross-market
# aggregate (cash, equity, market value, P/L) is held in this currency so a
# Rupiah (IDX) position and a US-dollar position can be summed correctly. Per
# the user base this is IDR; positions still keep their LOCAL price/avg-cost so
# each row reads naturally in its own currency.
BASE_CURRENCY = os.environ.get("TRADEWIZZ_SIM_BASE_CURRENCY", "IDR")

# Default starting cash, expressed in the base currency. Default: Rp1,000,000,000
# (one billion Rupiah) of simulated buying power.
DEFAULT_INITIAL_CASH = float(
    os.environ.get("TRADEWIZZ_SIM_INITIAL_CASH", "1000000000")
)

# A price provider takes (symbol, market) and returns the latest price or None.
PriceProvider = Callable[[str, Market], Optional[float]]


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
    ):
        self._price = price_provider
        self._store = store or SimulationStore()
        self._universe = universe or UniverseRepository()
        self._initial_cash = initial_cash

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
        accounting currency (IDR).

        ``idr_per_unit`` already expresses "how many IDR is 1 unit of this
        market's currency" (IDX=1, USD≈16000, ...). When the base currency is
        IDR this is exactly the factor we need; for any other base we'd divide
        by the base's own idr_per_unit, but IDR is the configured base.
        """
        try:
            per_unit_idr = market_config.idr_per_unit(market)
        except Exception:  # noqa: BLE001
            per_unit_idr = 1.0
        if BASE_CURRENCY == "IDR":
            return per_unit_idr
        # Generic fallback: convert via IDR. base_per_unit = idr_per_unit(mkt) /
        # idr_per_unit(base_market). We don't have a base Market handle here, so
        # IDR base is the supported path; default to no-op otherwise.
        return per_unit_idr

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
        return SimulatedAccount(
            user_id=user_id,
            cash=round(acct.cash, 2),
            equity=round(equity, 2),
            buying_power=round(acct.cash, 2),
            market_value=round(market_value, 2),
            unrealized_pnl=round(unrealized, 2),
            realized_pnl=round(acct.realized_pnl, 2),
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
        return SimulatedPortfolioSummary(account=account, positions=positions)

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
        exec_price = self._exec_price(sym, market, order_type, price)
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

    def reset(self, user_id: int) -> SimulatedAccount:
        self._store.reset(user_id, self._initial_cash, BASE_CURRENCY)
        return self.account(user_id)
