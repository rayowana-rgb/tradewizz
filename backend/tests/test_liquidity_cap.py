"""Phase F: liquidity-safe scoring.

A stock with zero / null / tiny value traded must never receive an elite
score or a BUY signal, regardless of how strong its technicals are. The cap is
applied AFTER the final calibrated/ML score and can never be overridden by
technical indicators.
"""

import numpy as np
import pandas as pd

from app import indicators, scoring
from app.engine import AnalysisEngine
from app.models import Market


# --------------------------------------------------------------------------- #
# Pure cap function                                                           #
# --------------------------------------------------------------------------- #
def test_zero_value_traded_is_illiquid_capped_at_50():
    for vt in (0, 0.0, -1, None):
        max_score, illiquid, reason = scoring.liquidity_cap_for(vt, Market.IDX)
        assert max_score == 50.0
        assert illiquid is True
        assert reason and "illiquid" in reason.lower()


def test_idx_tier_caps():
    # < Rp500M -> 50, < Rp1B -> 60, < Rp5B -> 75, >= Rp10B -> no cap.
    assert scoring.liquidity_cap_for(400_000_000, Market.IDX)[0] == 50.0
    assert scoring.liquidity_cap_for(800_000_000, Market.IDX)[0] == 60.0
    assert scoring.liquidity_cap_for(4_000_000_000, Market.IDX)[0] == 75.0
    assert scoring.liquidity_cap_for(20_000_000_000, Market.IDX)[0] is None


def test_us_tier_caps():
    assert scoring.liquidity_cap_for(400_000, Market.US)[0] == 50.0
    assert scoring.liquidity_cap_for(900_000, Market.US)[0] == 60.0
    assert scoring.liquidity_cap_for(4_000_000, Market.US)[0] == 75.0
    assert scoring.liquidity_cap_for(20_000_000, Market.US)[0] is None


def test_every_market_has_a_tiny_value_cap():
    tiny = {
        Market.IDX: 1_000,
        Market.US: 1_000,
        Market.JAPAN: 1_000,
        Market.INDIA: 1_000,
        Market.VIETNAM: 1_000,
        Market.SINGAPORE: 1_000,
        Market.HKEX: 1_000,
        Market.KOSPI: 1_000,
        Market.KOSDAQ: 1_000,
    }
    for market, vt in tiny.items():
        max_score, illiquid, _ = scoring.liquidity_cap_for(vt, market)
        assert max_score == 50.0, market
        assert illiquid is True, market


def test_apply_cap_forces_non_buy_and_lowers_score():
    ind = {"avg_value_traded": 0.0}
    score, signal, illiquid, reason = scoring.apply_liquidity_cap(
        95.0, "BUY", ind, Market.IDX
    )
    assert score <= 50.0
    assert signal != "BUY"
    assert illiquid is True
    assert reason


def test_apply_cap_passes_liquid_names_through_unchanged():
    ind = {"avg_value_traded": 50_000_000_000}  # Rp50B, very liquid
    score, signal, illiquid, reason = scoring.apply_liquidity_cap(
        92.0, "BUY", ind, Market.IDX
    )
    assert score == 92.0
    assert signal == "BUY"
    assert illiquid is False
    assert reason is None


# --------------------------------------------------------------------------- #
# End-to-end through the engine                                               #
# --------------------------------------------------------------------------- #
def _strong_uptrend(n=300, start=100.0, step=1.0, volume=1000.0):
    rng = np.random.default_rng(7)
    close = start + np.arange(n) * step + rng.normal(0.0, step * 1.5, n)
    vol = np.full(n, volume)
    return pd.DataFrame({
        "Open": close,
        "High": close + 1,
        "Low": close - 1,
        "Close": close,
        "Volume": vol,
    })


def test_engine_caps_illiquid_strong_technical_stock():
    # A strong uptrend but with microscopic volume -> value traded far below
    # the IDX floor. Technicals are great; liquidity is not.
    eng = AnalysisEngine(fetcher=lambda t, p, i: _strong_uptrend(volume=10.0))
    res = eng.analyze("TINY", Market.IDX)
    assert res.score <= 50.0
    assert res.signal != "BUY"
    assert res.illiquid is True
    assert res.liquidity_note


def test_engine_keeps_liquid_strong_stock_investable():
    # Same strong uptrend but with real liquidity -> not capped.
    eng = AnalysisEngine(
        fetcher=lambda t, p, i: _strong_uptrend(volume=30_000_000.0)
    )
    res = eng.analyze("BIG", Market.IDX)
    assert res.illiquid is False
    assert res.liquidity_note is None
    assert res.score > 50.0


def test_screener_flags_illiquid_but_still_lists_it():
    eng = AnalysisEngine(fetcher=lambda t, p, i: _strong_uptrend(volume=10.0))
    match = eng._screen_one("TINY", Market.IDX, {"TINY": "Tiny Co"})
    assert match.score <= 50.0
    assert match.signal != "BUY"
    assert match.illiquid is True
    assert match.liquidity_note == "Illiquid — not investable"


def test_liquidity_cap_uses_indicator_value_traded_path():
    df = _strong_uptrend(volume=10.0)
    ind = indicators.compute_all(df)
    # avg_value_traded is tiny here.
    vt = scoring._value_traded(ind)
    assert vt is not None and vt > 0
    max_score, illiquid, _ = scoring.liquidity_cap_for(vt, Market.IDX)
    assert max_score == 50.0 and illiquid is True
