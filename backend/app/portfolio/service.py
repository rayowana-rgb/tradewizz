"""Unified portfolio service: aggregate account + positions across brokers.

For each of a user's active broker connections, build the adapter and pull
account() + positions(). Aggregate into one summary + position list. Per-broker
failures (OpenD unreachable, IBKR stub not implemented) are recorded as
non-fatal errors so the rest of the portfolio still aggregates.
"""

from __future__ import annotations

from typing import Callable, List, Optional

from ..brokers.adapter import make_adapter
from ..brokers.service import BrokerConnectionService
from .models import (
    BrokerError,
    PortfolioPosition,
    PortfolioSummary,
    UnifiedPortfolio,
)


class PortfolioService:
    def __init__(
        self,
        connections: Optional[BrokerConnectionService] = None,
        adapter_factory: Callable = make_adapter,
    ):
        self._connections = connections or BrokerConnectionService()
        self._adapter_factory = adapter_factory

    def for_user(self, user_id: int) -> UnifiedPortfolio:
        summary = PortfolioSummary()
        positions: List[PortfolioPosition] = []
        brokers: List[str] = []
        errors: List[BrokerError] = []

        for conn in self._connections.list(user_id):
            if not conn.is_active:
                continue
            broker = conn.broker_type.value
            adapter = self._adapter_factory(conn.broker_type)
            contributed = False
            # Account-level figures.
            try:
                acct = adapter.account()
                if getattr(acct, "connected", True):
                    summary.cash += float(getattr(acct, "cash", 0) or 0)
                    summary.buying_power += float(
                        getattr(acct, "buying_power", 0) or 0
                    )
                    summary.total_equity += float(
                        getattr(acct, "total_assets", 0) or 0
                    )
                    contributed = True
            except Exception as exc:  # noqa: BLE001 - non-fatal per broker
                errors.append(BrokerError(broker=broker, message=str(exc)))
            # Positions.
            try:
                pos_resp = adapter.positions()
                for p in getattr(pos_resp, "positions", []) or []:
                    mv = float(getattr(p, "market_value", 0) or 0)
                    pl = float(getattr(p, "pl_value", 0) or 0)
                    summary.market_value += mv
                    summary.floating_pnl += pl
                    positions.append(PortfolioPosition(
                        symbol=p.symbol,
                        market=p.market,
                        broker=broker,
                        quantity=float(getattr(p, "quantity", 0) or 0),
                        average_cost=float(getattr(p, "cost_price", 0) or 0),
                        current_price=float(getattr(p, "current_price", 0) or 0),
                        market_value=mv,
                        unrealized_pnl=pl,
                    ))
                contributed = True
            except Exception as exc:  # noqa: BLE001 - non-fatal per broker
                errors.append(BrokerError(broker=broker, message=str(exc)))

            if contributed and broker not in brokers:
                brokers.append(broker)

        # Round for cleanliness.
        summary.total_equity = round(summary.total_equity, 2)
        summary.cash = round(summary.cash, 2)
        summary.buying_power = round(summary.buying_power, 2)
        summary.market_value = round(summary.market_value, 2)
        summary.floating_pnl = round(summary.floating_pnl, 2)
        summary.realized_pnl = round(summary.realized_pnl, 2)

        return UnifiedPortfolio(
            summary=summary,
            positions=positions,
            brokers=brokers,
            errors=errors,
        )
