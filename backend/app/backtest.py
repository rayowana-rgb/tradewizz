"""Historical signal generation + forward-return backtest.

Ports legacy `generate_historical_signals` / `backtest_signals` from bot9.py,
reusing the migrated indicator stack (`app/indicators.py`). Pure pandas/numpy,
no network. Signal rules mirror the legacy momentum/scalping/accumulation
buy logic.
"""

from __future__ import annotations

from typing import Dict

import numpy as np
import pandas as pd

from . import indicators

# Buy-signal rule families supported by /backtest.
SIGNAL_TYPES = ("momentum", "scalping", "accumulation")
DEFAULT_SIGNAL_TYPE = "momentum"
DEFAULT_FORWARD_DAYS = 2

# JSON has no Infinity; cap profit_factor when there are no losing trades.
PROFIT_FACTOR_CAP = 999.0


def _feature_frame(df: pd.DataFrame) -> pd.DataFrame:
    """Indicator columns needed by the signal rules, aligned to df.index."""
    close = df["Close"]
    volume = df["Volume"]
    macd_df = indicators.macd(close)
    bb = indicators.bollinger_bands(close)
    out = pd.DataFrame(index=df.index)
    out["Close"] = close
    out["Volume"] = volume
    out["RSI"] = indicators.rsi(close)
    out["MACD"] = macd_df["macd"]
    out["MACD_Signal"] = macd_df["signal"]
    out["MACD_Hist"] = macd_df["hist"]
    out["VWAP"] = indicators.vwap(df)
    out["SMA_50"] = indicators.sma(close, 50)
    out["OBV"] = indicators.obv(close, volume)
    out["AD"] = indicators.accum_dist(df)
    out["ADX"] = indicators.adx(df)
    out["BB_Upper"] = bb["upper"]
    out["Vol_Mean_10"] = volume.rolling(window=10, min_periods=10).mean()
    return out


def generate_historical_signals(
    df: pd.DataFrame, signal_type: str = DEFAULT_SIGNAL_TYPE
) -> pd.Series:
    """0/1 buy-signal series across history (legacy rule parity).

    Vectorized re-implementation of the legacy per-row rules. A signal at bar i
    uses bar i values and the i-1 (`prev`) comparisons.
    """
    if signal_type not in SIGNAL_TYPES:
        raise ValueError(f"unknown signal_type: {signal_type}")

    f = _feature_frame(df)
    prev = f.shift(1)
    sig = pd.Series(0, index=f.index, dtype="int64")

    if signal_type == "momentum":
        cond = (
            (f["RSI"] > 55)
            & (f["MACD"] > f["MACD_Signal"])
            & (f["MACD_Hist"] > prev["MACD_Hist"])
            & (f["Close"] > f["VWAP"])
            & (f["Close"] > f["SMA_50"])
            & (f["Volume"] > f["Vol_Mean_10"] * 1.5)
            & (f["ADX"] > 25)
            & (f["AD"] > prev["AD"])
            & (f["OBV"] > prev["OBV"])
        )
    elif signal_type == "scalping":
        cond = (
            (f["RSI"] > 50)
            & (f["RSI"] < 70)
            & (f["Close"] > f["VWAP"])
            & (f["MACD"] > f["MACD_Signal"])
            & (f["Close"] > f["BB_Upper"] * 0.97)
            & (f["AD"] > prev["AD"])
            & (f["Volume"] > f["Vol_Mean_10"] * 1.5)
        )
    else:  # accumulation
        cond = (
            (f["RSI"] > 50)
            & (f["RSI"] > prev["RSI"])
            & (f["MACD"] > f["MACD_Signal"])
            & (f["Close"] > f["VWAP"])
            & (f["Close"] > f["SMA_50"])
            & (f["OBV"] > prev["OBV"])
            & (f["AD"] > prev["AD"])
            & (f["Volume"] > f["Vol_Mean_10"] * 1.2)
        )

    sig[cond.fillna(False)] = 1
    return sig


def backtest_signals(
    df: pd.DataFrame,
    signals: pd.Series,
    forward_days: int = DEFAULT_FORWARD_DAYS,
) -> Dict[str, float]:
    """Forward-return stats for the bars where `signals == 1`.

    Returns win_rate, average_return, profit_factor, max_drawdown (all as
    fractions), and total_signals/total_wins/total_losses.
    """
    close = df["Close"].to_numpy(dtype="float64")
    sig = signals.to_numpy()
    n = len(close)

    returns = []
    for i in range(n - forward_days):
        if sig[i] == 1:
            buy = close[i]
            if buy == 0 or np.isnan(buy):
                continue
            future = close[i + forward_days]
            if np.isnan(future):
                continue
            returns.append(future / buy - 1.0)

    total = len(returns)
    if total == 0:
        return {
            "total_signals": 0,
            "total_wins": 0,
            "total_losses": 0,
            "win_rate": 0.0,
            "average_return": 0.0,
            "profit_factor": 0.0,
            "max_drawdown": 0.0,
        }

    arr = np.array(returns, dtype="float64")
    wins = arr[arr > 0]
    losses = arr[arr < 0]
    gross_win = float(wins.sum())
    gross_loss = float(-losses.sum())  # positive magnitude

    if gross_loss > 0:
        profit_factor = round(gross_win / gross_loss, 4)
    elif gross_win > 0:
        # Only winners: report a large finite sentinel (JSON has no Infinity).
        profit_factor = float(PROFIT_FACTOR_CAP)
    else:
        profit_factor = 0.0

    return {
        "total_signals": total,
        "total_wins": int((arr > 0).sum()),
        "total_losses": int((arr < 0).sum()),
        "win_rate": round(float((arr > 0).mean()), 4),
        "average_return": round(float(arr.mean()), 6),
        "profit_factor": profit_factor,
        "max_drawdown": round(float(arr.min()), 6),  # worst single-signal return
    }


def run_backtest(
    df: pd.DataFrame,
    signal_type: str = DEFAULT_SIGNAL_TYPE,
    forward_days: int = DEFAULT_FORWARD_DAYS,
) -> Dict[str, float]:
    """Convenience: generate signals then backtest them."""
    signals = generate_historical_signals(df, signal_type)
    return backtest_signals(df, signals, forward_days)
