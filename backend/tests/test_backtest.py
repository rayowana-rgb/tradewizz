"""Phase 5: historical signal generation + backtest (offline, synthetic)."""

import math

import numpy as np
import pandas as pd

from app.backtest import (
    PROFIT_FACTOR_CAP,
    SIGNAL_TYPES,
    backtest_signals,
    generate_historical_signals,
    run_backtest,
)
from app.engine import AnalysisEngine
from app.models import Market


def make_df(seed=7, n=400, drift=0.4, noise=1.5):
    rng = np.random.default_rng(seed)
    close = 100 + np.cumsum(rng.normal(drift, noise, n))
    close = np.maximum(close, 1.0)
    high = close + np.abs(rng.normal(0, 1, n)) + 0.5
    low = close - np.abs(rng.normal(0, 1, n)) - 0.5
    vol = rng.integers(1000, 8000, n).astype("float64")
    return pd.DataFrame(
        {"Open": close, "High": high, "Low": low, "Close": close, "Volume": vol}
    )


# --- signal generation ------------------------------------------------------

def test_generate_signals_is_binary_series():
    df = make_df()
    sig = generate_historical_signals(df, "momentum")
    assert sig.index.equals(df.index)
    assert set(sig.unique()).issubset({0, 1})


def test_all_signal_types_supported():
    df = make_df()
    for st in SIGNAL_TYPES:
        sig = generate_historical_signals(df, st)
        assert sig.sum() >= 0  # may be zero, never errors


def test_unknown_signal_type_raises():
    df = make_df()
    try:
        generate_historical_signals(df, "bogus")
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_flat_market_yields_no_momentum_signals():
    n = 200
    close = np.full(n, 100.0)
    df = pd.DataFrame(
        {"Open": close, "High": close, "Low": close, "Close": close,
         "Volume": np.full(n, 2000.0)}
    )
    assert generate_historical_signals(df, "momentum").sum() == 0


# --- backtest stats ---------------------------------------------------------

def test_backtest_stats_shape_and_bounds():
    df = make_df()
    sig = generate_historical_signals(df, "accumulation")
    stats = backtest_signals(df, sig, forward_days=2)
    for key in ("win_rate", "average_return", "profit_factor", "max_drawdown",
                "total_signals", "total_wins", "total_losses"):
        assert key in stats
    assert 0.0 <= stats["win_rate"] <= 1.0
    assert stats["total_wins"] + stats["total_losses"] <= stats["total_signals"]
    assert stats["max_drawdown"] <= 0.0 or stats["total_losses"] == 0


def test_backtest_no_signals_returns_zeros():
    df = make_df()
    empty = pd.Series(0, index=df.index)
    stats = backtest_signals(df, empty, forward_days=2)
    assert stats["total_signals"] == 0
    assert stats["win_rate"] == 0.0
    assert stats["profit_factor"] == 0.0
    assert stats["average_return"] == 0.0


def test_win_rate_and_returns_hand_computed():
    # Construct close so signals at known bars have known forward-2 returns.
    # close: index 0..5. Signals at 0 and 2 (forced); forward_days=2.
    close = pd.Series([100.0, 100, 110, 100, 90, 100])
    df = pd.DataFrame({
        "Open": close, "High": close, "Low": close, "Close": close,
        "Volume": [1000.0] * 6,
    })
    sig = pd.Series([1, 0, 1, 0, 0, 0], index=df.index)
    stats = backtest_signals(df, sig, forward_days=2)
    # bar0: 110/100-1 = +0.10 (win); bar2: 90/110-1 = -0.1818 (loss)
    assert stats["total_signals"] == 2
    assert stats["total_wins"] == 1
    assert stats["total_losses"] == 1
    assert stats["win_rate"] == 0.5
    win_ret = 110 / 100 - 1   # +0.10
    loss_ret = 90 / 110 - 1   # -0.1818
    assert math.isclose(
        stats["average_return"], (win_ret + loss_ret) / 2, abs_tol=1e-4
    )
    # profit_factor = gross_win / |gross_loss|
    assert math.isclose(
        stats["profit_factor"], win_ret / abs(loss_ret), abs_tol=1e-3
    )
    assert math.isclose(stats["max_drawdown"], loss_ret, abs_tol=1e-4)


def test_profit_factor_capped_when_no_losses():
    # All forward returns positive -> profit_factor is the finite cap.
    close = pd.Series([100.0, 101, 102, 103, 104, 105])
    df = pd.DataFrame({
        "Open": close, "High": close, "Low": close, "Close": close,
        "Volume": [1000.0] * 6,
    })
    sig = pd.Series([1, 1, 0, 0, 0, 0], index=df.index)
    stats = backtest_signals(df, sig, forward_days=2)
    assert stats["total_losses"] == 0
    assert stats["profit_factor"] == PROFIT_FACTOR_CAP
    assert math.isfinite(stats["profit_factor"])


def test_run_backtest_matches_components():
    df = make_df()
    combined = run_backtest(df, "momentum", 2)
    sig = generate_historical_signals(df, "momentum")
    separate = backtest_signals(df, sig, 2)
    assert combined == separate


# --- engine integration -----------------------------------------------------

def test_engine_backtest_returns_model():
    df = make_df()
    eng = AnalysisEngine(fetcher=lambda t, p, i: df)
    r = eng.backtest("BBCA", Market.IDX, "momentum", 2)
    assert r.symbol == "BBCA"
    assert r.market == Market.IDX
    assert r.signal_type == "momentum"
    assert r.forward_days == 2
    assert 0.0 <= r.win_rate <= 1.0
    assert math.isfinite(r.profit_factor)


def test_engine_backtest_offline_is_zeroed():
    def boom(t, p, i):
        raise ConnectionError("offline")

    r = AnalysisEngine(fetcher=boom).backtest("ZZZ", Market.IDX)
    assert r.total_signals == 0
    assert r.win_rate == 0.0
    assert r.profit_factor == 0.0
