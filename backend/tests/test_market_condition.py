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


# --- Breadth + VIX sentiment signals (optional, backward-compatible) ---

def _flat_closes(n: int = 260):
    # Perfectly flat -> price-only score is exactly NEUTRAL (50), so any shift
    # is attributable to the breadth/VIX signal under test.
    return [100.0] * n


def test_breadth_ratio_helper():
    from app.market.condition import _breadth_ratio
    assert _breadth_ratio(80, 20) == 0.6
    assert _breadth_ratio(20, 80) == -0.6
    assert _breadth_ratio(50, 50) == 0.0
    assert _breadth_ratio(None, 10) is None
    assert _breadth_ratio(10, None) is None
    assert _breadth_ratio(0, 0) is None


def test_breadth_default_none_is_backward_compatible():
    # No breadth/VIX passed -> identical to the legacy price-only call.
    closes = _flat_closes()
    assert classify_condition(closes).condition_score == \
        classify_condition(closes, advances=None, declines=None).condition_score


def test_broad_selling_lowers_score():
    base = classify_condition(_flat_closes()).condition_score
    bad = classify_condition(
        _flat_closes(), advances=10, declines=90
    ).condition_score
    assert bad < base, f"broad selling should lower score ({bad} !< {base})"


def test_broad_participation_raises_score():
    base = classify_condition(_flat_closes()).condition_score
    good = classify_condition(
        _flat_closes(), advances=90, declines=10
    ).condition_score
    assert good > base, f"broad buying should raise score ({good} !> {base})"


def test_high_vix_lowers_score():
    base = classify_condition(_flat_closes()).condition_score
    panic = classify_condition(_flat_closes(), vix=45.0).condition_score
    assert panic < base
    # Larger drop at panic levels than merely elevated.
    elevated = classify_condition(_flat_closes(), vix=32.0).condition_score
    assert panic <= elevated <= base


def test_low_vix_raises_score():
    base = classify_condition(_flat_closes()).condition_score
    calm = classify_condition(_flat_closes(), vix=12.0).condition_score
    assert calm > base


def test_vix_only_applies_for_us_market():
    # The service must not feed VIX to non-US markets even if a fetcher exists.
    import pandas as pd

    def fake_fetch(symbol, period="1y", interval="1d"):
        return pd.DataFrame({"Close": _flat_closes()})

    seen = {"vix_called": False}

    def fake_vix():
        seen["vix_called"] = True
        return 45.0

    svc = MarketConditionService(fetcher=fake_fetch, vix_fetcher=fake_vix)
    svc.get(Market.IDX)
    assert seen["vix_called"] is False, "VIX must not be fetched for non-US"

    svc.get(Market.US)
    assert seen["vix_called"] is True, "VIX should be fetched for US"


def test_breadth_provider_wired_into_service():
    import pandas as pd

    def fake_fetch(symbol, period="1y", interval="1d"):
        return pd.DataFrame({"Close": _flat_closes()})

    def heavy_selling(market):
        return (5, 95)

    svc = MarketConditionService(
        fetcher=fake_fetch, breadth_provider=heavy_selling
    )
    cond = svc.get(Market.IDX)
    # Flat index (price-only NEUTRAL 50) + broad selling -> pushed toward fear.
    assert cond.condition_score < 50
    assert cond.condition in ("FEAR", "EXTREME_FEAR", "NEUTRAL")


def test_breadth_provider_failure_is_swallowed():
    import pandas as pd

    def fake_fetch(symbol, period="1y", interval="1d"):
        return pd.DataFrame({"Close": _flat_closes()})

    def boom(market):
        raise RuntimeError("breadth source down")

    svc = MarketConditionService(fetcher=fake_fetch, breadth_provider=boom)
    cond = svc.get(Market.IDX)
    # Falls back to the price-only reading without crashing (breadth ignored).
    price_only = classify_condition(_flat_closes()).condition_score
    assert cond.condition == "NEUTRAL"
    assert cond.condition_score == price_only


# --- Multi-horizon (daily / weekly / monthly) breakdown ---

def test_multi_horizon_returns_three_horizons():
    from app.market import classify_multi_horizon
    closes = [100 + i * 0.4 for i in range(260)]
    cond = classify_multi_horizon(closes)
    d = cond.to_dict()
    assert "horizons" in d
    names = [h["horizon"] for h in d["horizons"]]
    assert names == ["daily", "weekly", "monthly"]
    for h in d["horizons"]:
        assert h["condition"] in (
            "EXTREME_FEAR", "FEAR", "NEUTRAL", "GREED", "EXTREME_GREED",
            "UNKNOWN",
        )
        if h["available"]:
            assert 0 <= h["condition_score"] <= 100
        assert isinstance(h["reason"], str)


def test_multi_horizon_top_level_matches_classify_condition():
    # Drop-in: the headline fields equal the single-reading classifier.
    from app.market import classify_multi_horizon
    closes = [100 + i * 0.4 for i in range(260)]
    multi = classify_multi_horizon(closes)
    single = classify_condition(closes)
    assert multi.condition == single.condition
    assert multi.condition_score == single.condition_score


def test_classify_condition_has_no_horizons_key():
    # Legacy callers are untouched (no horizons leaked into the old reading).
    closes = [100 + i * 0.4 for i in range(260)]
    assert "horizons" not in classify_condition(closes).to_dict()


def test_daily_horizon_cools_on_recent_plunge_within_uptrend():
    # Year-long uptrend with a sharp final-week selloff: the daily horizon must
    # read less greedy than the monthly horizon (near-term fear, regime intact).
    from app.market import classify_multi_horizon
    closes = [100 + i * 0.4 for i in range(260)]
    for k in range(1, 8):
        closes[-k] = closes[-8] - k * 2.5
    hs = {h["horizon"]: h["condition_score"]
          for h in classify_multi_horizon(closes).to_dict()["horizons"]}
    assert hs["daily"] < hs["monthly"], hs


def test_daily_horizon_warms_on_recent_bounce_within_downtrend():
    # Year-long downtrend with a recent bounce: daily > monthly.
    from app.market import classify_multi_horizon
    closes = [300 - i * 0.6 for i in range(260)]
    for k in range(1, 8):
        closes[-k] = closes[-8] + k * 3.0
    hs = {h["horizon"]: h["condition_score"]
          for h in classify_multi_horizon(closes).to_dict()["horizons"]}
    assert hs["daily"] >= hs["monthly"], hs


def test_multi_horizon_missing_data_degrades_gracefully():
    from app.market import classify_multi_horizon
    cond = classify_multi_horizon(None)
    assert cond.condition == "UNKNOWN"
    # horizons present but each unavailable, no crash.
    d = cond.to_dict()
    assert "horizons" in d
    for h in d["horizons"]:
        assert h["available"] is False


def test_condition_endpoint_exposes_horizons():
    import pandas as pd

    def fake_fetch(symbol, period="1y", interval="1d"):
        closes = [100 + i * 0.4 for i in range(260)]
        return pd.DataFrame({"Close": closes})

    set_market_condition_service(MarketConditionService(fetcher=fake_fetch))
    client = TestClient(app)
    r = client.get("/v1/market/condition", params={"market": "IDX"})
    assert r.status_code == 200
    body = r.json()
    assert "horizons" in body
    assert {h["horizon"] for h in body["horizons"]} == {
        "daily", "weekly", "monthly"
    }
