"""Institutional-grade multi-factor scoring: quality + ranking consistency.

Covers app.scoring (pure factor functions, penalties, calibration, blend) and
its integration in AnalysisEngine. Verifies the Phase 1-4 spec:
  * weighted composite with the exact factor weights;
  * each factor's banding (trend stack, RSI sweet spot, ATR%, etc.);
  * hard quality penalties (gap / pump-dump / spike / extreme ATR / micro);
  * calibration distribution (only a small % reach 90+);
  * applied identically to all 9 markets;
  * monotonic ranking consistency.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from app import indicators, scoring
from app.engine import AnalysisEngine
from app.models import Market
from app.scoring import MarketContext

ALL_MARKETS = [
    Market.IDX, Market.US, Market.JAPAN, Market.INDIA, Market.VIETNAM,
    Market.SINGAPORE, Market.HKEX, Market.KOSPI, Market.KOSDAQ,
]


# --------------------------------------------------------------------------- #
# Weights                                                                     #
# --------------------------------------------------------------------------- #
def test_factor_weights_match_spec_and_sum_to_one():
    assert scoring.WEIGHTS == {
        "trend": 0.25, "momentum": 0.20, "volume": 0.15,
        "relative_strength": 0.15, "volatility": 0.10,
        "market_regime": 0.10, "liquidity": 0.05,
    }
    assert abs(sum(scoring.WEIGHTS.values()) - 1.0) < 1e-9


# --------------------------------------------------------------------------- #
# Trend score                                                                 #
# --------------------------------------------------------------------------- #
def test_trend_full_bullish_stack_with_bonuses():
    ind = {"ema20": 110, "ema50": 105, "ema200": 100, "close": 112,
           "high_52w": 112}
    # 100 base + 10 (above ema200) + 15 (52w high), clamped to 100.
    assert scoring.trend_score(ind) == 100.0


def test_trend_full_bearish_stack_is_zero():
    ind = {"ema20": 90, "ema50": 95, "ema200": 100, "close": 85}
    assert scoring.trend_score(ind) == 0.0


def test_trend_partial_up_and_down():
    # ema20 > ema50 but not a full stack (ema200 above) -> 70.
    assert scoring.trend_score({"ema20": 106, "ema50": 105, "close": 80,
                                "ema200": 120}) == 70.0
    # ema20 < ema50 but NOT a full bearish stack (ema200 below ema50) -> 30.
    assert scoring.trend_score({"ema20": 104, "ema50": 105, "close": 80,
                                "ema200": 90}) == 30.0


def test_trend_neutral_when_missing():
    assert scoring.trend_score({}) == scoring.NEUTRAL


# --------------------------------------------------------------------------- #
# Momentum score                                                              #
# --------------------------------------------------------------------------- #
def test_momentum_sweet_spot_beats_overbought():
    optimal = scoring.momentum_score(
        {"rsi": 62, "macd_hist": 0.5, "roc": 6, "adx": 30})
    extreme = scoring.momentum_score(
        {"rsi": 90, "macd_hist": 0.5, "roc": 6, "adx": 30})
    assert optimal > extreme
    assert optimal >= 80
    # RSI 90 is heavily penalized.
    assert extreme < optimal - 20


def test_momentum_neutral_when_missing():
    assert scoring.momentum_score({}) == scoring.NEUTRAL


# --------------------------------------------------------------------------- #
# Volume score                                                                #
# --------------------------------------------------------------------------- #
def test_volume_strong_surge_high():
    ind = {"vol_ratio_5_20": 2.5, "cmf": 0.2, "obv": 100, "obv_prev": 50}
    assert scoring.volume_score(ind) >= 90


def test_volume_weak_low():
    ind = {"vol_ratio_5_20": 0.5, "cmf": -0.2, "obv": 50, "obv_prev": 100}
    assert scoring.volume_score(ind) < 30


def test_volume_renormalizes_with_partial_inputs():
    # Only volume ratio present -> still a valid 0..100 score.
    s = scoring.volume_score({"vol_ratio_5_20": 2.5})
    assert 0.0 <= s <= 100.0


# --------------------------------------------------------------------------- #
# Relative strength                                                           #
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("pct,expected", [
    (0.95, 100.0), (0.80, 80.0), (0.50, 50.0), (0.05, 20.0)])
def test_relative_strength_percentile_bands(pct, expected):
    assert scoring.relative_strength_score(
        MarketContext(rs_percentile=pct)) == expected


@pytest.mark.parametrize("rs,expected", [
    (0.20, 100.0), (0.08, 80.0), (0.0, 50.0), (-0.10, 20.0)])
def test_relative_strength_value_bands(rs, expected):
    assert scoring.relative_strength_score(MarketContext(rs_value=rs)) == expected


def test_relative_strength_neutral_without_context():
    assert scoring.relative_strength_score(None) == scoring.NEUTRAL
    assert scoring.relative_strength_score(MarketContext()) == scoring.NEUTRAL


# --------------------------------------------------------------------------- #
# Volatility                                                                  #
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize("atr,expected", [
    (4.0, 100.0), (1.8, 75.0), (9.0, 50.0), (0.5, 30.0), (20.0, 10.0)])
def test_volatility_bands(atr, expected):
    assert scoring.volatility_score({"atr_pct": atr}) == expected


# --------------------------------------------------------------------------- #
# Market regime                                                               #
# --------------------------------------------------------------------------- #
def test_market_regime_bands():
    assert scoring.market_regime_score(MarketContext(regime="bull")) == 100.0
    assert scoring.market_regime_score(MarketContext(regime="bear")) == 20.0
    assert scoring.market_regime_score(MarketContext(regime="neutral")) == 50.0
    assert scoring.market_regime_score(None) == scoring.NEUTRAL


# --------------------------------------------------------------------------- #
# Liquidity (per-market floors)                                               #
# --------------------------------------------------------------------------- #
def test_liquidity_uses_per_market_floor():
    # $2M floor for US: exactly at floor -> 70; 5x -> 100; far below -> low.
    assert scoring.liquidity_score({"avg_value_traded": 2_000_000}, Market.US) == 70.0
    assert scoring.liquidity_score({"avg_value_traded": 12_000_000}, Market.US) == 100.0
    assert scoring.liquidity_score({"avg_value_traded": 100_000}, Market.US) <= 25.0
    # IDX floor is Rp10B (much larger) -> the same $2M would be tiny.
    assert scoring.liquidity_score({"avg_value_traded": 2_000_000}, Market.IDX) <= 25.0


# --------------------------------------------------------------------------- #
# Quality penalties (Phase 2)                                                 #
# --------------------------------------------------------------------------- #
def test_gap_penalty():
    p = scoring.quality_penalty(
        {"close": 130, "prev_close": 100}, Market.US)  # +30% gap
    assert p >= 20.0


def test_pump_and_dump_penalty():
    ind = {"close": 5.0, "prev_close": 4.9, "pct_change_3": 0.60,
           "rsi": 88, "ema20": 4.0, "ema50": 4.5, "volume_ratio": 3,
           "atr_pct": 8}
    # untrended (ema20<ema50) + +60% 3d + RSI88 -> pump-dump 30.
    assert scoring.quality_penalty(ind, Market.US) >= 30.0


def test_volume_spike_without_trend_penalty():
    ind = {"close": 50, "prev_close": 49, "volume_ratio": 12,
           "ema20": 48, "ema50": 49}  # spike 12x, untrended
    assert scoring.quality_penalty(ind, Market.US) >= 25.0


def test_extreme_atr_penalty():
    assert scoring.quality_penalty({"close": 50, "atr_pct": 20}, Market.US) >= 20.0


def test_micro_price_penalty():
    assert scoring.quality_penalty({"close": 0.5}, Market.US) >= 15.0  # < $1
    assert scoring.quality_penalty({"close": 5.0}, Market.US) == 0.0


# --------------------------------------------------------------------------- #
# Composite + calibration                                                     #
# --------------------------------------------------------------------------- #
def test_composite_uses_exact_weights():
    ind = {}  # all factors neutral=50 (missing inputs)
    ctx = None
    raw = scoring.composite_raw(ind, ctx, Market.US)
    # All seven factors == 50, weights sum to 1 -> composite 50, no penalties.
    assert raw == pytest.approx(50.0, abs=1e-6)


def test_calibration_is_monotonic_and_gates_elite():
    xs = list(range(0, 101, 2))
    ys = [scoring.calibrate(x) for x in xs]
    assert ys == sorted(ys)  # monotonic non-decreasing
    # 90+ requires a very high raw composite (elite gate).
    assert scoring.calibrate(85) < 90
    assert scoring.calibrate(92) >= 90
    assert scoring.calibrate(50) < 60


def test_elite_band_is_rare_across_random_universe():
    # Simulate a universe of raw composites ~ realistic spread; <=10% pass 90.
    rng = np.random.default_rng(0)
    raws = np.clip(rng.normal(60, 14, 5000), 0, 100)
    calibrated = np.array([scoring.calibrate(r) for r in raws])
    elite_frac = float((calibrated >= 90).mean())
    assert elite_frac <= 0.10  # spec: only ~3-10% reach elite


# --------------------------------------------------------------------------- #
# ML blend                                                                    #
# --------------------------------------------------------------------------- #
def test_blend_formula():
    assert scoring.blend_with_ml(80.0, 0.5) == pytest.approx(0.7 * 80 + 0.3 * 50)
    assert scoring.blend_with_ml(80.0, None) == 80.0
    # Clamped 0..100.
    assert 0.0 <= scoring.blend_with_ml(100.0, 1.0) <= 100.0


def test_signal_bands():
    assert scoring.signal_for_score(75) == "BUY"
    assert scoring.signal_for_score(60) == "HOLD"
    assert scoring.signal_for_score(40) == "SELL"


# --------------------------------------------------------------------------- #
# Engine integration: identical across markets + ranking consistency          #
# --------------------------------------------------------------------------- #
def _trend_df(n=300, start=5000.0, step=8.0, seed=3, vol_lo=1e6, vol_hi=3e6):
    # start/step large enough to clear every market's micro-price floor.
    rng = np.random.default_rng(seed)
    close = start + np.arange(n) * step + rng.normal(0, abs(step) * 1.4, n)
    close = np.clip(close, 1.0, None)
    vol = np.linspace(vol_lo, vol_hi, n) * rng.uniform(0.85, 1.25, n)
    return pd.DataFrame({"Open": close, "High": close + 1.5,
                         "Low": close - 1.5, "Close": close, "Volume": vol})


def test_same_score_for_same_data_across_all_markets():
    # The scoring is market-agnostic except the liquidity floor. With turnover
    # well above every market's floor, the technical score must be identical.
    df = _trend_df(vol_lo=5e10, vol_hi=9e10)  # huge turnover clears all floors
    ind = indicators.compute_all(df)
    ctx = MarketContext(rs_value=0.10, regime="bull")
    scores = {m: scoring.technical_score(ind, ctx, m) for m in ALL_MARKETS}
    assert len(set(round(s, 6) for s in scores.values())) == 1


def test_score_is_deterministic():
    df = _trend_df()
    ind = indicators.compute_all(df)
    ctx = MarketContext(rs_value=0.05, regime="bull")
    a = scoring.technical_score(ind, ctx, Market.US)
    b = scoring.technical_score(ind, ctx, Market.US)
    assert a == b


def test_ranking_consistency_better_setup_scores_higher():
    # Strong outperformer in a bull market vs a weak laggard in a bear market.
    strong = indicators.compute_all(_trend_df(seed=1, vol_lo=5e10, vol_hi=9e10))
    weak = indicators.compute_all(
        _trend_df(seed=2, start=8000, step=-8.0, vol_lo=9e10, vol_hi=5e10))
    s_strong = scoring.technical_score(
        strong, MarketContext(rs_value=0.15, regime="bull"), Market.US)
    s_weak = scoring.technical_score(
        weak, MarketContext(rs_value=-0.15, regime="bear"), Market.US)
    assert s_strong > s_weak


def test_engine_screen_ranks_strong_above_weak(tmp_path):
    def fetch(ticker, period, interval):
        if ticker.startswith("^"):
            return _trend_df(seed=9)  # bull index
        if ticker.startswith("GOOD"):
            return _trend_df(seed=1, vol_lo=5e10, vol_hi=9e10)
        return _trend_df(seed=2, start=8000, step=-8.0,
                         vol_lo=9e10, vol_hi=5e10)

    eng = AnalysisEngine(fetcher=fetch)
    res = eng.screen(Market.US, symbols=["GOOD1", "BAD1", "GOOD2", "BAD2"])
    syms = [m.symbol for m in res.matches]
    # All GOOD names rank above all BAD names.
    good_idx = [i for i, s in enumerate(syms) if s.startswith("GOOD")]
    bad_idx = [i for i, s in enumerate(syms) if s.startswith("BAD")]
    assert max(good_idx) < min(bad_idx)
    scores = [m.score for m in res.matches]
    assert scores == sorted(scores, reverse=True)
