"""Market-close screener result caching.

Heavy screening only runs once per market/category after market close. The
result is persisted as a `ScreenerSnapshot` and reused (no rerun) until the
next market-close screening for the same market/category/params. This keeps the
app fast: opening it many times does not re-screen the whole universe.

Nothing here touches the scoring formula, indicators, the Yahoo data source,
the analysis engine, broker logic, or portfolio logic.
"""

from .store import (
    InMemoryScreenerSnapshotStore,
    ScreenerSnapshotRecord,
    ScreenerSnapshotStore,
    SqliteScreenerSnapshotStore,
)

__all__ = [
    "InMemoryScreenerSnapshotStore",
    "ScreenerSnapshotRecord",
    "ScreenerSnapshotStore",
    "SqliteScreenerSnapshotStore",
]
