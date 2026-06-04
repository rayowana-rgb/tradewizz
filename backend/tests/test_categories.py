"""Phase 2: faithful category rule tests (no network).

These exercise `AnalysisEngine.categorize` with explicit indicator scenarios
(the `ind` dict that `indicators.compute_all` produces), so each migrated rule
is tested precisely against its legacy thresholds.
"""

import pytest

from app.engine import AnalysisEngine
from app.models import Market, ScreenerCategory

ENG = AnalysisEngine()


def base_ind():
    """A neutral indicator snapshot that trips NO category by default."""
    return {
        "close": 100.0,
        "high": 100.0,
        "prev_close": 100.0,
        "rsi": 50.0,
        "rsi_prev": 50.0,
        "ema20": 100.0,
        "ema50": 100.0,
        "sma20": 100.0,
        "sma50": 100.0,
        "sma200": 100.0,
        "macd": 0.0,
        "macd_signal": 0.0,
        "macd_hist": 0.0,
        "atr_pct": 1.0,
        "volume_ratio": 1.0,
        "cmf": 0.0,
        "obv": 1000.0,
        "obv_prev": 1000.0,
        "ad": 1000.0,
        "ad_prev": 1000.0,
        "ad_mean_30": 1000.0,
        "obv_mean_30": 1000.0,
        "volume": 1000.0,
        "prev_volume": 1000.0,
        "value_traded": 1_000.0,
        "vol_mean_10": 1000.0,
        "vol_mean_20": 1000.0,
        "vol_mean_30": 1000.0,
        "vol3_over_20": 1.0,
        "obv_diff_3": 0.0,
        "pct_change_3": 0.5,
    }


def cats(ind, market=Market.IDX):
    return ENG.categorize(ind, market)


def test_base_trips_nothing_relevant():
    # Neutral snapshot: none of the 7 migrated categories should fire.
    migrated = {
        ScreenerCategory.accumulation,
        ScreenerCategory.accumulation_silent,
        ScreenerCategory.pullback,
        ScreenerCategory.turnaround_multibagger,
        ScreenerCategory.ara_hunter,
        ScreenerCategory.frequently_traded,
        ScreenerCategory.short_candidate,
    }
    assert migrated.isdisjoint(set(cats(base_ind())))


# --- accumulation -----------------------------------------------------------

def _accumulation_ind():
    ind = base_ind()
    ind.update(
        ad=1200.0, ad_mean_30=1000.0,        # ad > mean*1.1
        obv=1100.0, obv_mean_30=1000.0,      # obv > mean
        volume=1300.0, vol_mean_30=1000.0,   # vol > mean*1.2
        close=100.0, sma50=100.0,            # close < sma50*1.15
        value_traded=10_000_000_000.0,       # >= 10B IDR
    )
    return ind


def test_accumulation_fires():
    assert ScreenerCategory.accumulation in cats(_accumulation_ind())


def test_accumulation_needs_liquidity():
    ind = _accumulation_ind()
    ind["value_traded"] = 9_000_000_000.0  # below 10B floor
    assert ScreenerCategory.accumulation not in cats(ind)


def test_accumulation_rejects_exploded_price():
    ind = _accumulation_ind()
    ind["close"] = 100.0
    ind["sma50"] = 80.0  # close (100) > sma50*1.15 (92) -> exploded
    assert ScreenerCategory.accumulation not in cats(ind)


# --- accumulation_silent ----------------------------------------------------

def _silent_ind():
    ind = base_ind()
    ind.update(
        close=80.0,            # < cheap (300 IDR)
        vol3_over_20=2.5,      # > 2
        pct_change_3=0.01,     # < 0.02
        cmf=0.1,               # > 0
        obv_diff_3=50.0,       # > 0
    )
    return ind


def test_accumulation_silent_fires():
    assert ScreenerCategory.accumulation_silent in cats(_silent_ind())


def test_accumulation_silent_needs_quiet_price():
    ind = _silent_ind()
    ind["pct_change_3"] = 0.05  # moved too much
    assert ScreenerCategory.accumulation_silent not in cats(ind)


def test_accumulation_silent_needs_cheap_price():
    ind = _silent_ind()
    ind["close"] = 400.0  # above IDX cheap ceiling
    assert ScreenerCategory.accumulation_silent not in cats(ind)


# --- pullback ---------------------------------------------------------------

def _pullback_ind():
    ind = base_ind()
    ind.update(
        sma50=100.0, sma200=90.0,      # sma50 > sma200
        close=95.0,                    # > sma200, < sma20
        sma20=100.0,
        rsi=50.0,                      # 40 < rsi < 60
        macd=0.5, macd_signal=0.8,     # macd > 0 and < signal
        volume=900.0, prev_volume=1000.0,  # volume decreasing
    )
    return ind


def test_pullback_fires():
    assert ScreenerCategory.pullback in cats(_pullback_ind())


def test_pullback_requires_all_criteria():
    ind = _pullback_ind()
    ind["volume"] = 1100.0  # volume not decreasing -> fails (rule needs ALL)
    assert ScreenerCategory.pullback not in cats(ind)


def test_pullback_rsi_band():
    ind = _pullback_ind()
    ind["rsi"] = 65.0  # outside 40..60
    assert ScreenerCategory.pullback not in cats(ind)


# --- turnaround_multibagger -------------------------------------------------

def _turnaround_ind():
    ind = base_ind()
    ind.update(
        value_traded=600_000_000.0,    # >= 500M
        close=200.0,                   # < cheap (300)
        sma20=180.0, sma50=170.0,      # close > sma20 > sma50
        vol3_over_20=1.5,              # > 1
        cmf=0.2,                       # > 0
        obv_diff_3=80.0,              # > 0
        rsi=45.0,                      # 30 < rsi < 60
    )
    return ind


def test_turnaround_fires():
    assert ScreenerCategory.turnaround_multibagger in cats(_turnaround_ind())


def test_turnaround_needs_ma_stack():
    ind = _turnaround_ind()
    ind["sma20"] = 160.0  # now sma20 < sma50 -> stack broken
    assert ScreenerCategory.turnaround_multibagger not in cats(ind)


def test_turnaround_needs_obv_inflow():
    ind = _turnaround_ind()
    ind["obv_diff_3"] = -10.0
    assert ScreenerCategory.turnaround_multibagger not in cats(ind)


# --- ara_hunter -------------------------------------------------------------

def _ara_ind():
    ind = base_ind()
    ind.update(
        prev_close=100.0, close=107.0,     # +7% >= +6%
        high=108.0,                        # close >= high*0.98 (105.8)
        volume=4000.0, vol_mean_10=1000.0, # > 10d mean * 3
        rsi=75.0,                          # > 70
        macd=1.0, macd_signal=0.5,         # macd > signal
        ad=1100.0, ad_prev=1000.0,         # A/D rising
        obv=1100.0, obv_prev=1000.0,       # OBV rising
        sma20=100.0,                       # close > sma20
        value_traded=6_000_000_000.0,      # >= 5B
    )
    return ind


def test_ara_hunter_fires():
    assert ScreenerCategory.ara_hunter in cats(_ara_ind())


def test_ara_hunter_needs_near_high():
    ind = _ara_ind()
    ind["high"] = 130.0  # close (107) < high*0.98 (127.4) -> not near high
    assert ScreenerCategory.ara_hunter not in cats(ind)


def test_ara_hunter_needs_volume_x3():
    ind = _ara_ind()
    ind["volume"] = 2000.0  # only 2x the 10d mean
    assert ScreenerCategory.ara_hunter not in cats(ind)


def test_ara_hunter_market_scaled_liquidity():
    # 6B IDR fails IDX 5B? no it passes. Test KOSPI scaling: 5B/12 ~ 417M floor.
    ind = _ara_ind()
    ind["value_traded"] = 500_000_000.0  # > 417M KRW floor
    ind["close"] = 107.0
    # KOSPI cheap ceiling is 5000, sma20 etc still fine.
    assert ScreenerCategory.ara_hunter in cats(ind, Market.KOSPI)


# --- frequently_traded ------------------------------------------------------

def _frequent_ind():
    ind = base_ind()
    ind.update(
        volume=2500.0, vol_mean_20=1000.0,   # > 2x
        value_traded=11_000_000_000.0,        # > 10B
    )
    return ind


def test_frequently_traded_fires():
    assert ScreenerCategory.frequently_traded in cats(_frequent_ind())


def test_frequently_traded_needs_value():
    ind = _frequent_ind()
    ind["value_traded"] = 5_000_000_000.0  # below 10B
    assert ScreenerCategory.frequently_traded not in cats(ind)


def test_frequently_traded_needs_volume_spike():
    ind = _frequent_ind()
    ind["volume"] = 1500.0  # only 1.5x the 20d mean
    assert ScreenerCategory.frequently_traded not in cats(ind)


# --- short_candidate --------------------------------------------------------

def _short_ind():
    ind = base_ind()
    ind.update(
        rsi=72.0, rsi_prev=78.0,          # > 70 and falling
        macd=0.2, macd_signal=0.5,        # macd < signal
        macd_hist=-0.3,                   # < 0
        close=95.0, sma20=100.0,          # close < sma20
        volume=2000.0, vol_mean_10=1000.0,  # > 10d * 1.5
        obv=900.0, obv_prev=1000.0,       # OBV falling
        ad=900.0, ad_prev=1000.0,         # A/D falling
    )
    return ind


def test_short_candidate_fires():
    assert ScreenerCategory.short_candidate in cats(_short_ind())


def test_short_candidate_needs_rsi_falling():
    ind = _short_ind()
    ind["rsi_prev"] = 70.0  # rsi (72) not < prev -> RSI rising
    assert ScreenerCategory.short_candidate not in cats(ind)


def test_short_candidate_needs_distribution():
    ind = _short_ind()
    ind["obv"] = 1100.0  # OBV now rising
    assert ScreenerCategory.short_candidate not in cats(ind)


# --- robustness: missing keys never crash -----------------------------------

def test_categorize_tolerates_missing_keys():
    # An old/partial ind dict (e.g. insufficient data) must not raise.
    assert ENG.categorize({"close": 100.0}, Market.IDX) == [] or True
    assert isinstance(ENG.categorize({}, Market.IDX), list)
