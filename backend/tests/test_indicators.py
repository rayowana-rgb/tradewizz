"""Indicator math tests with synthetic data (no network)."""

import numpy as np
import pandas as pd

from app import indicators


def _series(values):
    return pd.Series(values, dtype="float64")


def test_ema_matches_pandas_ewm():
    s = _series([1, 2, 3, 4, 5])
    out = indicators.ema(s, span=3)
    expected = s.ewm(span=3, adjust=False).mean()
    assert np.allclose(out.values, expected.values)


def test_sma_warmup_then_value():
    s = _series([1, 2, 3, 4])
    out = indicators.sma(s, window=2)
    assert np.isnan(out.iloc[0])
    assert out.iloc[1] == 1.5
    assert out.iloc[3] == 3.5


def test_rsi_all_gains_is_100():
    s = _series(list(range(1, 40)))  # monotonic up
    out = indicators.rsi(s, period=14).dropna()
    assert out.iloc[-1] == 100.0


def test_rsi_bounds():
    rng = np.random.default_rng(42)
    s = _series(100 + np.cumsum(rng.normal(0, 1, 200)))
    out = indicators.rsi(s).dropna()
    assert (out >= 0).all() and (out <= 100).all()


def test_macd_hist_is_macd_minus_signal():
    rng = np.random.default_rng(1)
    s = _series(100 + np.cumsum(rng.normal(0, 1, 100)))
    m = indicators.macd(s)
    assert np.allclose((m["macd"] - m["signal"]).values, m["hist"].values)


def test_atr_positive():
    rng = np.random.default_rng(7)
    close = 100 + np.cumsum(rng.normal(0, 1, 100))
    high = close + np.abs(rng.normal(0, 1, 100))
    low = close - np.abs(rng.normal(0, 1, 100))
    df = pd.DataFrame({"High": high, "Low": low, "Close": close})
    out = indicators.atr(df).dropna()
    assert (out > 0).all()


def test_volume_ratio_around_one_for_flat_volume():
    v = _series([1000] * 30)
    out = indicators.volume_ratio(v, window=20)
    assert abs(out.iloc[-1] - 1.0) < 1e-9


def test_compute_all_has_expected_keys():
    rng = np.random.default_rng(3)
    n = 300
    close = 100 + np.cumsum(rng.normal(0, 1, n))
    df = pd.DataFrame(
        {
            "Open": close,
            "High": close + 1,
            "Low": close - 1,
            "Close": close,
            "Volume": rng.integers(1000, 5000, n),
        }
    )
    ind = indicators.compute_all(df)
    for key in [
        "close", "rsi", "ema20", "ema50", "sma200",
        "macd", "macd_signal", "macd_hist", "volume_ratio", "atr", "atr_pct",
    ]:
        assert key in ind
    assert ind["close"] is not None
    assert ind["sma200"] is not None  # 300 rows >= 200


# ---------------------------------------------------------------------------
# Phase 1 indicators (OBV, A/D, CMF, VWAP, ADX, Bollinger, SMA20/50, value)
# ---------------------------------------------------------------------------


def _ohlcv(close, high=None, low=None, volume=None):
    close = np.asarray(close, dtype="float64")
    n = len(close)
    high = close + 1.0 if high is None else np.asarray(high, dtype="float64")
    low = close - 1.0 if low is None else np.asarray(low, dtype="float64")
    volume = (
        np.full(n, 1000.0) if volume is None else np.asarray(volume, "float64")
    )
    return pd.DataFrame(
        {"Open": close, "High": high, "Low": low, "Close": close,
         "Volume": volume}
    )


def test_sma20_and_sma50_warmup():
    s = _series(list(range(1, 60)))
    assert np.isnan(indicators.sma(s, 20).iloc[18])
    assert not np.isnan(indicators.sma(s, 20).iloc[19])
    assert not np.isnan(indicators.sma(s, 50).iloc[49])


def test_obv_directionality():
    # up, up, down, up -> +V, +V, -V, +V
    close = _series([10, 11, 12, 11, 12])
    vol = _series([100, 200, 300, 400, 500])
    out = indicators.obv(close, vol)
    # first bar diff is 0 -> sign 0 -> +0; then cumulative signed volume.
    assert list(out.values) == [0.0, 200.0, 500.0, 100.0, 600.0]


def test_accum_dist_flat_bar_contributes_zero():
    # Bar 2 is flat (High==Low) -> zero money flow; A/D unchanged across it.
    df = _ohlcv(
        close=[10, 10, 12],
        high=[11, 10, 13],
        low=[9, 10, 11],
        volume=[100, 999, 100],
    )
    out = indicators.accum_dist(df)
    assert out.iloc[1] == out.iloc[0]  # flat bar added nothing


def test_accum_dist_full_buy_and_sell_bars():
    # Close at High -> CLV +1; Close at Low -> CLV -1.
    buy = _ohlcv(close=[10], high=[10], low=[8], volume=[100])  # close==high
    assert indicators.accum_dist(buy).iloc[-1] == 100.0
    sell = _ohlcv(close=[8], high=[10], low=[8], volume=[100])  # close==low
    assert indicators.accum_dist(sell).iloc[-1] == -100.0


def test_cmf_bounds_and_sign():
    rng = np.random.default_rng(11)
    n = 60
    close = 100 + np.cumsum(rng.normal(0, 1, n))
    df = _ohlcv(close, high=close + 2, low=close - 2,
                volume=rng.integers(1000, 5000, n))
    out = indicators.cmf(df, window=20).dropna()
    assert (out >= -1.0001).all() and (out <= 1.0001).all()
    # All-buy bars (close at high) -> CMF == +1.
    allbuy = _ohlcv(close=[10] * 25, high=[10] * 25, low=[8] * 25)
    assert abs(indicators.cmf(allbuy, 20).iloc[-1] - 1.0) < 1e-9


def test_vwap_equals_price_when_constant():
    df = _ohlcv(close=[10] * 10, high=[10] * 10, low=[10] * 10,
                volume=[100, 200, 300, 100, 50, 75, 25, 400, 10, 90])
    out = indicators.vwap(df)
    assert abs(out.iloc[-1] - 10.0) < 1e-9


def test_vwap_is_volume_weighted():
    # Two bars: typical 10 (vol 100) and 20 (vol 300) -> vwap = (10*100+20*300)/400
    df = _ohlcv(close=[10, 20], high=[10, 20], low=[10, 20], volume=[100, 300])
    assert abs(indicators.vwap(df).iloc[-1] - 17.5) < 1e-9


def test_adx_bounds_and_strong_trend():
    rng = np.random.default_rng(5)
    # Strong steady uptrend -> high ADX.
    n = 120
    close = 100 + np.arange(n) * 1.0
    df = _ohlcv(close, high=close + 0.5, low=close - 0.5,
                volume=rng.integers(1000, 2000, n))
    out = indicators.adx(df).dropna()
    assert (out >= 0).all() and (out <= 100).all()
    assert out.iloc[-1] > 40  # clean trend -> strong ADX


def test_adx_low_in_choppy_market():
    # Oscillating (no trend) -> low ADX.
    n = 120
    close = 100 + np.tile([0, 1, 0, -1], n // 4)
    df = _ohlcv(close, high=close + 0.5, low=close - 0.5)
    out = indicators.adx(df).dropna()
    assert out.iloc[-1] < 40


def test_bollinger_bands_geometry():
    rng = np.random.default_rng(9)
    close = _series(100 + np.cumsum(rng.normal(0, 1, 100)))
    bb = indicators.bollinger_bands(close, window=20, num_std=2.0).dropna()
    assert (bb["upper"] >= bb["middle"]).all()
    assert (bb["middle"] >= bb["lower"]).all()
    # Middle band == SMA20.
    sma20 = indicators.sma(close, 20)
    assert np.allclose(
        bb["middle"].values, sma20.dropna().values[-len(bb):], equal_nan=False
    )


def test_bollinger_width_zero_for_constant_series():
    bb = indicators.bollinger_bands(_series([5.0] * 30), 20, 2.0)
    last = bb.iloc[-1]
    assert last["upper"] == last["middle"] == last["lower"] == 5.0


def test_compute_all_includes_phase1_keys_and_value_traded():
    rng = np.random.default_rng(7)
    n = 300
    close = 100 + np.cumsum(rng.normal(0, 1, n))
    vol = rng.integers(1000, 5000, n).astype("float64")
    df = _ohlcv(close, high=close + 1, low=close - 1, volume=vol)
    ind = indicators.compute_all(df)
    for key in [
        "sma20", "sma50", "obv", "obv_prev", "ad", "ad_prev", "cmf",
        "vwap", "adx", "bb_upper", "bb_middle", "bb_lower",
        "volume", "value_traded",
    ]:
        assert key in ind
    assert ind["sma20"] is not None and ind["sma50"] is not None
    assert ind["value_traded"] is not None
    # value_traded == last close * last volume.
    assert abs(ind["value_traded"] - ind["close"] * ind["volume"]) < 1e-6


def test_compute_all_existing_keys_unchanged():
    # Phase 1 must not alter the pre-existing keys/values used by scoring.
    rng = np.random.default_rng(3)
    n = 300
    close = 100 + np.cumsum(rng.normal(0, 1, n))
    df = pd.DataFrame(
        {"Open": close, "High": close + 1, "Low": close - 1, "Close": close,
         "Volume": rng.integers(1000, 5000, n)}
    )
    ind = indicators.compute_all(df)
    # Recompute the scoring inputs directly and compare.
    assert ind["ema20"] == _last(indicators.ema(df["Close"], 20))
    assert ind["ema50"] == _last(indicators.ema(df["Close"], 50))
    assert ind["sma200"] == _last(indicators.sma(df["Close"], 200))
    assert ind["macd_hist"] == _last(indicators.macd(df["Close"])["hist"])


def _last(series):
    s = series.dropna()
    return float(s.iloc[-1]) if not s.empty else None
