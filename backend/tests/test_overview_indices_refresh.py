"""Market overview + indices refresh after their cache window (req 9).

These services hold a short in-memory TTL cache on top of fresh fetches, so a
new trading day's data is picked up without a backend restart once the window
elapses. Yahoo is mocked via injected fetchers (no network).
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

from app.market import MarketIndicesService
from app.market.overview import MarketOverviewService
from app.models import Market, ScreenerMatch, ScreenerResult

JKT = ZoneInfo("Asia/Jakarta")


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, s):
        self.t += s


def _index_df(close: float) -> pd.DataFrame:
    idx = pd.date_range(end="2026-06-08", periods=5, freq="D")
    closes = np.linspace(close - 4, close, 5)
    return pd.DataFrame(
        {"Open": closes, "High": closes + 1, "Low": closes - 1,
         "Close": closes, "Volume": np.full(5, 0.0)},
        index=idx,
    )


def test_indices_refresh_after_ttl():
    state = {"close": 7000.0, "calls": 0}

    def fetch(symbol, period, interval):
        state["calls"] += 1
        return _index_df(state["close"])

    clock = Clock()
    svc = MarketIndicesService(
        fetcher=fetch, ttl_seconds=300, clock=clock,
        now_provider=lambda m: datetime(2026, 6, 8, 11, 0, tzinfo=JKT),
    )
    first = svc.get_indices()
    calls_after_first = state["calls"]
    assert calls_after_first >= 1

    # Within TTL -> served from cache, no new fetches.
    svc.get_indices()
    assert state["calls"] == calls_after_first

    # New trading day's data arrives; after the TTL window the cache refreshes.
    state["close"] = 7100.0
    clock.advance(301)
    second = svc.get_indices()
    assert state["calls"] > calls_after_first
    idx_first = next(q for q in first if q.market is Market.IDX)
    idx_second = next(q for q in second if q.market is Market.IDX)
    assert idx_second.price != idx_first.price


def _screen_result(market, top_score):
    return ScreenerResult(
        market=market,
        matches=[ScreenerMatch(
            symbol="AAA", name="AAA", score=top_score, signal="BUY",
            price=100.0, change_percent=1.0,
        )],
        generated_at="2026-06-08T00:00:00+00:00",
        total_count=1, returned_count=1, limit=50,
        market_status="CLOSED",
    )


def test_overview_refreshes_after_ttl():
    state = {"score": 90.0, "calls": 0}

    def run_screen(market):
        state["calls"] += 1
        return _screen_result(market, state["score"])

    clock = Clock()
    # TTL-isolation test: disable the data-freshness probe so only the time
    # TTL governs caching here (the probe is covered by dedicated tests).
    svc = MarketOverviewService(
        run_screen, ttl_seconds=300, clock=clock, latest_data_timestamp=None
    )

    first = svc.get(Market.IDX)
    assert state["calls"] == 1

    # Within TTL -> cached.
    svc.get(Market.IDX)
    assert state["calls"] == 1

    # After TTL -> rebuilt from fresh screen (new day's data).
    state["score"] = 95.0
    clock.advance(301)
    second = svc.get(Market.IDX)
    assert state["calls"] == 2
    # The overview reflects the refreshed screen (movers/data changed).
    assert second is not first
