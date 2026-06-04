"""Pure pandas/numpy technical indicators.

No TA-Lib dependency (keeps the backend portable). Each function takes a
pandas Series/DataFrame of OHLCV and returns a Series aligned to the input
index. NaNs appear during the warm-up period (expected).
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def ema(series: pd.Series, span: int) -> pd.Series:
    """Exponential moving average."""
    return series.ewm(span=span, adjust=False).mean()


def sma(series: pd.Series, window: int) -> pd.Series:
    """Simple moving average."""
    return series.rolling(window=window, min_periods=window).mean()


def rsi(close: pd.Series, period: int = 14) -> pd.Series:
    """Wilder's RSI (0..100)."""
    delta = close.diff()
    gain = delta.clip(lower=0.0)
    loss = -delta.clip(upper=0.0)
    # Wilder smoothing == EMA with alpha = 1/period.
    avg_gain = gain.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    out = 100 - (100 / (1 + rs))
    # When avg_loss is 0 (all gains) RSI is 100.
    out = out.where(avg_loss != 0, 100.0)
    return out


def macd(
    close: pd.Series,
    fast: int = 12,
    slow: int = 26,
    signal: int = 9,
) -> pd.DataFrame:
    """MACD line, signal line, and histogram."""
    macd_line = ema(close, fast) - ema(close, slow)
    signal_line = macd_line.ewm(span=signal, adjust=False).mean()
    hist = macd_line - signal_line
    return pd.DataFrame(
        {"macd": macd_line, "signal": signal_line, "hist": hist}
    )


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Average True Range (Wilder smoothing). Expects High/Low/Close columns."""
    high = df["High"]
    low = df["Low"]
    close = df["Close"]
    prev_close = close.shift(1)
    tr = pd.concat(
        [
            (high - low),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    return tr.ewm(alpha=1 / period, adjust=False, min_periods=period).mean()


def volume_ratio(volume: pd.Series, window: int = 20) -> pd.Series:
    """Latest volume relative to its trailing average (1.0 == average)."""
    avg = volume.rolling(window=window, min_periods=1).mean()
    return volume / avg.replace(0.0, np.nan)


def compute_all(df: pd.DataFrame) -> dict:
    """Compute the full indicator set from an OHLCV DataFrame.

    Returns a dict of latest scalar values (plus a few prior values used for
    crossover/trend detection). Values may be None if there isn't enough data.
    """

    def last(series: pd.Series):
        s = series.dropna()
        return float(s.iloc[-1]) if not s.empty else None

    def prev(series: pd.Series):
        s = series.dropna()
        return float(s.iloc[-2]) if len(s) >= 2 else None

    close = df["Close"]
    macd_df = macd(close)

    rsi_s = rsi(close)
    ema20_s = ema(close, 20)
    ema50_s = ema(close, 50)
    sma200_s = sma(close, 200)
    vr_s = volume_ratio(df["Volume"])
    atr_s = atr(df)

    last_close = last(close)
    last_atr = last(atr_s)

    return {
        "close": last_close,
        "rsi": last(rsi_s),
        "ema20": last(ema20_s),
        "ema50": last(ema50_s),
        "sma200": last(sma200_s),
        "macd": last(macd_df["macd"]),
        "macd_signal": last(macd_df["signal"]),
        "macd_hist": last(macd_df["hist"]),
        "macd_hist_prev": prev(macd_df["hist"]),
        "volume_ratio": last(vr_s),
        "atr": last_atr,
        "atr_pct": (last_atr / last_close * 100)
        if (last_atr is not None and last_close not in (None, 0))
        else None,
    }
