"""Unified portfolio service: aggregate account + positions across brokers.

For each of a user's active broker connections, build the adapter and pull
account() + positions(). Aggregate into one summary + position list. Per-broker
failures (OpenD unreachable, IBKR stub not implemented) are recorded as
non-fatal errors so the rest of the portfolio still aggregates.
"""

from __future__ import annotations

import logging
import queue
import threading
import time
from typing import Callable, List, Optional

from ..brokers.adapter import make_adapter
from ..brokers.models import BrokerType
from ..brokers.service import BrokerConnectionService
from .models import (
    BrokerError,
    PortfolioPosition,
    PortfolioSummary,
    UnifiedPortfolio,
)

logger = logging.getLogger("tradewizz.portfolio")

# Per-broker hard timeout. One slow/down broker (e.g. Moomoo OpenD hanging)
# must NOT block the others (req 5): each broker is fetched in its own worker
# and a broker that exceeds this is recorded as a non-fatal error so the rest
# of the portfolio (including IBKR) still returns promptly. Generous enough to
# cover an IBKR connect (connect_timeout ~4s) plus account+positions.
_BROKER_FETCH_TIMEOUT = 12.0


class PortfolioService:
    def __init__(
        self,
        connections: Optional[BrokerConnectionService] = None,
        adapter_factory: Callable = make_adapter,
    ):
        self._connections = connections or BrokerConnectionService()
        self._adapter_factory = adapter_factory

    def _fetch_broker(self, conn) -> dict:
        """Fetch one broker's account + positions. Self-contained so it can run
        in its own worker with a timeout. Never raises: per-broker failures are
        returned as non-fatal errors. (req 5/6)

        We do NOT call adapter.status() here: it would add a redundant IBKR
        connect on the same clientId (a connect race) and 'connected' is
        already derived from whether account()/positions() succeed.
        """
        broker = conn.broker_type.value
        is_ibkr = conn.broker_type is BrokerType.IBKR
        adapter = self._adapter_factory(conn.broker_type)
        errors: List[BrokerError] = []
        contributed = False
        acct = None
        out_positions: list = []

        try:
            acct = adapter.account()
            if is_ibkr:
                logger.info(
                    "IBKR portfolio diagnostics: account.connected=%s "
                    "cash=%s total_assets=%s",
                    getattr(acct, "connected", None),
                    getattr(acct, "cash", None),
                    getattr(acct, "total_assets", None),
                )
            if getattr(acct, "connected", True):
                contributed = True
            else:
                errors.append(BrokerError(
                    broker=broker,
                    message=f"{broker} is not reachable; its data is excluded.",
                ))
        except Exception as exc:  # noqa: BLE001 - non-fatal per broker
            errors.append(BrokerError(broker=broker, message=str(exc)))

        try:
            pos_resp = adapter.positions()
            if is_ibkr:
                logger.info(
                    "IBKR portfolio diagnostics: positions.connected=%s "
                    "count=%d",
                    getattr(pos_resp, "connected", None),
                    len(getattr(pos_resp, "positions", []) or []),
                )
            if getattr(pos_resp, "connected", True):
                out_positions = list(getattr(pos_resp, "positions", []) or [])
                contributed = True
        except Exception as exc:  # noqa: BLE001 - non-fatal per broker
            errors.append(BrokerError(broker=broker, message=str(exc)))

        return {
            "broker": broker, "contributed": contributed,
            "acct": acct, "positions": out_positions, "errors": errors,
        }

    def for_user(self, user_id: int) -> UnifiedPortfolio:
        summary = PortfolioSummary()
        positions: List[PortfolioPosition] = []
        brokers: List[str] = []
        errors: List[BrokerError] = []

        active = [c for c in self._connections.list(user_id) if c.is_active]

        # Fetch every broker concurrently with a per-broker timeout so a slow
        # or down broker (e.g. Moomoo OpenD hanging) never blocks the others
        # (req 5). DAEMON threads (not ThreadPoolExecutor, whose context exit
        # joins on shutdown) push results into a queue; we collect against a
        # wall-clock deadline and NEVER join a slow worker, so a 30s hang in
        # one broker cannot delay the request beyond the timeout.
        results: List[dict] = []
        if active:
            q: "queue.Queue[dict]" = queue.Queue()

            def _worker(conn):
                broker = conn.broker_type.value
                try:
                    q.put(self._fetch_broker(conn))
                except Exception as exc:  # noqa: BLE001
                    q.put({
                        "broker": broker, "contributed": False,
                        "acct": None, "positions": [],
                        "errors": [BrokerError(
                            broker=broker, message=str(exc))],
                    })

            for conn in active:
                threading.Thread(
                    target=_worker, args=(conn,), daemon=True,
                    name=f"portfolio-{conn.broker_type.value}",
                ).start()

            deadline = time.monotonic() + _BROKER_FETCH_TIMEOUT
            seen_brokers: set = set()
            for _ in active:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    res = q.get(timeout=remaining)
                except queue.Empty:
                    break
                results.append(res)
                seen_brokers.add(res["broker"])
            # Any broker that did not report in time is a non-fatal timeout;
            # its (daemon) worker is abandoned and the request returns now.
            for conn in active:
                b = conn.broker_type.value
                if b not in seen_brokers:
                    logger.warning(
                        "portfolio: %s did not respond within %.0fs; excluded",
                        b, _BROKER_FETCH_TIMEOUT,
                    )
                    results.append({
                        "broker": b, "contributed": False,
                        "acct": None, "positions": [],
                        "errors": [BrokerError(
                            broker=b,
                            message=f"{b} timed out; data excluded.",
                        )],
                    })

        # Merge results deterministically (single-threaded; no shared-state
        # races on the summary aggregation).
        for res in results:
            broker = res["broker"]
            errors.extend(res["errors"])
            acct = res["acct"]
            contributed = res["contributed"]
            if acct is not None and getattr(acct, "connected", True):
                summary.cash += float(getattr(acct, "cash", 0) or 0)
                summary.buying_power += float(
                    getattr(acct, "buying_power", 0) or 0)
                summary.total_equity += float(
                    getattr(acct, "total_assets", 0) or 0)
            for p in res["positions"]:
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
