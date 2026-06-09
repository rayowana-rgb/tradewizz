"""Portfolio Health Score + Position Quality (Elite).

Analyzes the user's SIMULATED portfolio only (no broker, no real positions).
Reuses the existing scoring engine for per-symbol quality inputs and computes:

  * Portfolio Health Score (0-100) from diversification, concentration risk,
    liquidity, quality, and sector/market exposure.
  * Per-position Quality Score (0-100) from trend, relative strength, momentum,
    volume, and risk.
  * Warnings / exit signals.

No new indicators or scoring logic are introduced; only existing engine output
is aggregated.
"""

from .models import (
    PortfolioHealth,
    PositionQuality,
    PositionQualityResponse,
)
from .service import PortfolioHealthService

__all__ = [
    "PortfolioHealth",
    "PositionQuality",
    "PositionQualityResponse",
    "PortfolioHealthService",
]
