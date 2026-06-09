"""Phase E: rule-based Fear/Greed market condition."""

import numpy as np
import pandas as pd
from fastapi.testclient import TestClient

from app.main import app, set_market_condition_service
from app.market import MarketConditionService, classify_condition
from app.models import Market


def test_bullish_index_is_greed():
    # Steady uptrend, near highs, low volatility -> Greed / Extreme Greed.
    closes = [100 + i * 0.8 for i in range(260)]
    cond = classify_condition(closes)
    assert cond.condition in ("GREED", "EXTREME_GREED")
    assert cond.condition_score >= 61
    assert cond.reason


def test_bearish_drawdown_is_fear():
    # Sustained decline + deep drawdown -> Fear / Extreme Fear.
    closes = [300 - i * 0.8 for i in range(260)]
    cond = classify_condition(closes)
    assert cond.condition in ("FEAR", "EXTREME_FEAR")
    assert cond.condition_score <= 40


def test_mixed_market_is_neutral():
    # Flat, range-bound index sitting right on its averages with no trend and
    # ending mid-range -> Neutral. A perfectly flat line keeps `last` equal to
    # all moving averages and mid-range vs the 52w high/low.
    closes = [100.0] * 260
    cond = classify_condition(closes)
    assert cond.condition == "NEUTRAL", (
        f"got {cond.condition} ({cond.condition_score})"
    )
    assert 41 <= cond.condition_score <= 60


def test_missing_data_is_unknown_without_crash():
    assert classify_condition(None).condition == "UNKNOWN"
    assert classify_condition([]).condition == "UNKNOWN"
    assert classify_condition([100, 101, 102]).condition == "UNKNOWN"
    # score stays neutral, never crashes.
    assert classify_condition(None).condition_score == 50


def test_score_bands_are_monotonic():
    # Bullish score > neutral score > bearish score.
    bull = classify_condition([100 + i for i in range(260)]).condition_score
    bear = classify_condition([300 - i for i in range(260)]).condition_score
    flat = classify_condition([100.0] * 260).condition_score
    assert bull > flat > bear


def test_condition_endpoint_returns_band():
    def fake_fetch(symbol, period="1y", interval="1d"):
        closes = [100 + i * 0.8 for i in range(260)]
        return pd.DataFrame({"Close": closes})

    set_market_condition_service(MarketConditionService(fetcher=fake_fetch))
    client = TestClient(app)
    r = client.get("/v1/market/condition", params={"market": "IDX"})
    assert r.status_code == 200
    body = r.json()
    assert body["market"] == "IDX"
    assert body["condition"] in (
        "EXTREME_FEAR", "FEAR", "NEUTRAL", "GREED", "EXTREME_GREED", "UNKNOWN"
    )
    assert 0 <= body["condition_score"] <= 100
    assert isinstance(body["reason"], str)


def test_condition_service_handles_fetch_failure():
    def boom(symbol, period="1y", interval="1d"):
        raise RuntimeError("no data")

    svc = MarketConditionService(fetcher=boom)
    cond = svc.get(Market.US)
    assert cond.condition == "UNKNOWN"
    assert cond.condition_score == 50
