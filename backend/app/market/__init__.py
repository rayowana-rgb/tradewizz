"""Market index data (Dashboard).

Exposes the latest index price/change for each supported market via Yahoo
Finance, with a short in-memory cache. Independent of the screener snapshot
cache and of the scoring/analysis engine.
"""

from .service import (
    INDEX_BY_MARKET,
    IndexQuote,
    MarketIndicesService,
    MarketIndexSpec,
)

__all__ = [
    "INDEX_BY_MARKET",
    "IndexQuote",
    "MarketIndexSpec",
    "MarketIndicesService",
]
