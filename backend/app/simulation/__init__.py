"""Simulated paper-trading portfolio.

A pure local paper-trading portfolio. NO broker connection, NO external order,
NO IBKR/Moomoo call. Buy/Sell are simulated against the latest price from the
existing analysis/fetch engine and persisted per user in SQLite.

Every response is marked ``simulated=true`` and carries a clear disclaimer that
no real broker order is sent.
"""

from .models import (
    SimulatedAccount,
    SimulatedOrderPreview,
    SimulatedOrderRequest,
    SimulatedOrderResult,
    SimulatedPortfolioSummary,
    SimulatedPosition,
    SimulatedTrade,
)
from .service import SimulationError, SimulationService

__all__ = [
    "SimulatedAccount",
    "SimulatedOrderPreview",
    "SimulatedOrderRequest",
    "SimulatedOrderResult",
    "SimulatedPortfolioSummary",
    "SimulatedPosition",
    "SimulatedTrade",
    "SimulationError",
    "SimulationService",
]
