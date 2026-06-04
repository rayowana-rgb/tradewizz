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
