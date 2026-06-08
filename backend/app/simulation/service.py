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

# Default starting cash: 1,000,000 USD-equivalent (configurable via env).
DEFAULT_INITIAL_CASH = float(
    os.environ.get("TRADEWIZZ_SIM_INITIAL_CASH", "1000000")
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

    # -- account / portfolio ---------------------------------------------
    def _account_model(
        self, user_id: int, positions: List[SimulatedPosition]
    ) -> SimulatedAccount:
        acct: AccountRow = self._store.get_or_create_account(
            user_id, self._initial_cash
        )
        market_value = sum(p.market_value for p in positions)
        unrealized = sum(p.unrealized_pnl for p in positions)
        equity = acct.cash + market_value
        return SimulatedAccount(
            user_id=user_id,
            cash=round(acct.cash, 2),
            equity=round(equity, 2),
            buying_power=round(acct.cash, 2),
            market_value=round(market_value, 2),
            unrealized_pnl=round(unrealized, 2),
            realized_pnl=round(acct.realized_pnl, 2),
            currency=acct.currency,
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
        return self._account_model(user_id, self.positions(user_id))

    def portfolio(self, user_id: int) -> SimulatedPortfolioSummary:
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
        est_value = quantity * exec_price
        acct = self._store.get_or_create_account(user_id, self._initial_cash)

        if side == "BUY":
            if est_value > acct.cash + 1e-9:
                raise SimulationError(
                    "Insufficient simulated cash for this order.", 400
                )
            cash_after = acct.cash - est_value
        else:  # SELL
            pos = self._store.get_position(user_id, sym, market.value)
            held = pos.quantity if pos else 0.0
            if quantity > held + 1e-9:
                raise SimulationError(
                    "Cannot sell more than the simulated quantity held.", 400
                )
            cash_after = acct.cash + est_value

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
        value = quantity * exec_price
        acct = self._store.get_or_create_account(user_id, self._initial_cash)
        pos = self._store.get_position(user_id, sym, market.value)

        realized = 0.0
        if side == "BUY":
            if value > acct.cash + 1e-9:
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
            new_cash = acct.cash - value
        else:  # SELL
            held = pos.quantity if pos else 0.0
            if quantity > held + 1e-9:
                raise SimulationError(
                    "Cannot sell more than the simulated quantity held.", 400
                )
            avg = pos.average_cost if pos else 0.0
            realized = (exec_price - avg) * quantity
            remaining = held - quantity
            new_realized = (pos.realized_pnl if pos else 0.0) + realized
            if remaining <= 1e-9:
                self._store.delete_position(user_id, sym, market.value)
            else:
                self._store.upsert_position(
                    user_id, sym, market.value, remaining, avg, new_realized
                )
            new_cash = acct.cash + value

        new_account_realized = acct.realized_pnl + realized
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
        self._store.reset(user_id, self._initial_cash)
        return self.account(user_id)
