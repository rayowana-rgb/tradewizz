"""Market index data (Dashboard).

Exposes the latest index price/change for each supported market via Yahoo
Finance, with a short in-memory cache. Independent of the screener snapshot
cache and of the scoring/analysis engine.
"""

from .overview import (
    ForeignFlow,
    MarketOverview,
    MarketOverviewService,
    MoverRef,
)
from .condition import MarketCondition, classify_condition
from .service import (
    INDEX_BY_MARKET,
    IndexQuote,
    MarketConditionService,
    MarketIndicesService,
    MarketIndexSpec,
)

__all__ = [
    "INDEX_BY_MARKET",
    "ForeignFlow",
    "IndexQuote",
    "MarketCondition",
    "MarketConditionService",
    "MarketIndexSpec",
    "MarketIndicesService",
    "classify_condition",
    "MarketOverview",
    "MarketOverviewService",
    "MoverRef",
]
