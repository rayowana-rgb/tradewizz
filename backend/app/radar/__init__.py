"""AI Opportunity Radar, Daily Market Picks, and Multibagger Finder.

All three reuse the EXISTING scoring/screener engine (no new scoring logic, no
indicator changes, no universe changes). They re-rank the screener output by a
composite of score, liquidity, relative strength, and market regime, and attach
plain-language recommendations / opportunity reasons. Research only — these are
not trade signals to a broker.
"""

from .models import (
    DailyPick,
    DailyPicksResponse,
    MultibaggerCandidate,
    MultibaggerResponse,
    OpportunitiesResponse,
    Opportunity,
)
from .service import RadarService

__all__ = [
    "DailyPick",
    "DailyPicksResponse",
    "MultibaggerCandidate",
    "MultibaggerResponse",
    "OpportunitiesResponse",
    "Opportunity",
    "RadarService",
]
