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


def roc(close: pd.Series, period: int = 12) -> pd.Series:
    """Rate of Change (%) over `period` bars: (close/close[-period] - 1)*100."""
    return (close / close.shift(period) - 1.0) * 100.0


def obv(close: pd.Series, volume: pd.Series) -> pd.Series:
    """On-Balance Volume: cumulative volume signed by daily price direction."""
    direction = np.sign(close.diff().fillna(0.0))
    return (direction * volume).cumsum()


def accum_dist(df: pd.DataFrame) -> pd.Series:
    """Accumulation/Distribution line (Chaikin A/D).

    CLV = ((Close-Low) - (High-Close)) / (High-Low); A/D = cumsum(CLV * Volume).
    A flat bar (High==Low) contributes zero money-flow.
    """
    high = df["High"]
    low = df["Low"]
    close = df["Close"]
    volume = df["Volume"]
    span = (high - low)
    clv = ((close - low) - (high - close)) / span.replace(0.0, np.nan)
    clv = clv.fillna(0.0)  # flat bars -> no flow
    return (clv * volume).cumsum()


def cmf(df: pd.DataFrame, window: int = 20) -> pd.Series:
    """Chaikin Money Flow over `window` (sum money-flow volume / sum volume)."""
    high = df["High"]
    low = df["Low"]
    close = df["Close"]
    volume = df["Volume"]
    span = (high - low)
    mfm = ((close - low) - (high - close)) / span.replace(0.0, np.nan)
    mfm = mfm.fillna(0.0)
    mfv = mfm * volume
    vol_sum = volume.rolling(window=window, min_periods=window).sum()
    return mfv.rolling(window=window, min_periods=window).sum() / vol_sum.replace(
        0.0, np.nan
    )


def vwap(df: pd.DataFrame) -> pd.Series:
    """Cumulative Volume-Weighted Average Price over the frame.

    Uses the typical price (H+L+C)/3. This is a running VWAP across the whole
    series (suitable for daily bars), not a session-reset intraday VWAP.
    """
    typical = (df["High"] + df["Low"] + df["Close"]) / 3.0
    volume = df["Volume"]
    cum_vol = volume.cumsum()
    return (typical * volume).cumsum() / cum_vol.replace(0.0, np.nan)


def adx(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """Average Directional Index (Wilder), 0..100 trend-strength."""
    high = df["High"]
    low = df["Low"]
    close = df["Close"]

    up_move = high.diff()
    down_move = -low.diff()
    plus_dm = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    plus_dm = pd.Series(plus_dm, index=df.index)
    minus_dm = pd.Series(minus_dm, index=df.index)

    prev_close = close.shift(1)
    tr = pd.concat(
        [
            (high - low),
            (high - prev_close).abs(),
            (low - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)

    alpha = 1 / period
    atr_s = tr.ewm(alpha=alpha, adjust=False, min_periods=period).mean()
    plus_di = 100 * (
        plus_dm.ewm(alpha=alpha, adjust=False, min_periods=period).mean()
        / atr_s.replace(0.0, np.nan)
    )
    minus_di = 100 * (
        minus_dm.ewm(alpha=alpha, adjust=False, min_periods=period).mean()
        / atr_s.replace(0.0, np.nan)
    )
    di_sum = (plus_di + minus_di).replace(0.0, np.nan)
    dx = 100 * (plus_di - minus_di).abs() / di_sum
    return dx.ewm(alpha=alpha, adjust=False, min_periods=period).mean()


def bollinger_bands(
    close: pd.Series, window: int = 20, num_std: float = 2.0
) -> pd.DataFrame:
    """Bollinger Bands: middle (SMA), upper, lower (population std)."""
    middle = close.rolling(window=window, min_periods=window).mean()
    std = close.rolling(window=window, min_periods=window).std(ddof=0)
    return pd.DataFrame(
        {
            "middle": middle,
            "upper": middle + num_std * std,
            "lower": middle - num_std * std,
        }
    )


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
    volume = df["Volume"]
    macd_df = macd(close)

    def roll_mean_series(series: pd.Series, w: int):
        s = series.rolling(window=w, min_periods=w).mean()
        return last(s)

    rsi_s = rsi(close)
    ema20_s = ema(close, 20)
    ema50_s = ema(close, 50)
    ema200_s = ema(close, 200)
    sma200_s = sma(close, 200)
    vr_s = volume_ratio(volume)
    atr_s = atr(df)

    # Phase-1 institutional scoring inputs (additive keys only).
    roc_s = roc(close, 12)                       # 12-bar momentum %
    high_52w_s = close.rolling(window=252, min_periods=20).max()
    avg_value_traded = roll_mean_series(close * volume, 20)  # 20d turnover
    vol_mean_5 = roll_mean_series(volume, 5)
    vol_mean_20_avt = roll_mean_series(volume, 20)
    vol_ratio_5_20 = (
        vol_mean_5 / vol_mean_20_avt
        if (vol_mean_5 is not None and vol_mean_20_avt not in (None, 0))
        else None
    )
    # Phase 11B liquidity-first inputs (additive aliases; nothing renamed).
    last_close_lf = last(close)
    last_volume_lf = last(volume)
    value_traded_today = (
        last_close_lf * last_volume_lf
        if (last_close_lf is not None and last_volume_lf is not None)
        else None
    )
    # today volume vs 20d average volume.
    volume_ratio_20d = (
        last_volume_lf / vol_mean_20_avt
        if (last_volume_lf is not None and vol_mean_20_avt not in (None, 0))
        else None
    )
    # today turnover vs 20d average turnover.
    value_traded_ratio_20d = (
        value_traded_today / avg_value_traded
        if (value_traded_today is not None
            and avg_value_traded not in (None, 0))
        else None
    )

    # ------------------------------------------------------------------ #
    # Microstructure liquidity proxies (order-book quality from OHLCV).   #
    # A name can post high turnover yet still be hard to enter/exit       #
    # without moving price when the bid/offer queue is thin and gappy.    #
    # With only OHLCV (no Level-2 depth) we approximate that "tightness"  #
    # from how much price swings per unit of money traded, plus how often #
    # the name simply does not trade.                                     #
    #                                                                     #
    #   illiquidity_impact : Amihud-style 20d mean of                     #
    #       |daily return| / turnover  (scaled). HIGH = illiquid (price   #
    #       moves a lot per rupiah traded => thin, bolong order book).    #
    #   range_pct_20d      : 20d mean of (High-Low)/Close * 100. HIGH =   #
    #       gappy/jumpy tape (a tight book trades in small steps).        #
    #   zero_volume_days_20d : no-trade sessions in the last 20 (dead      #
    #       queue). HIGH = illiquid.                                       #
    # All are additive keys; nothing existing is renamed or rescored.     #
    # ------------------------------------------------------------------ #
    high_s = df["High"]
    low_s = df["Low"]
    daily_ret_abs = close.pct_change(fill_method=None).abs()
    daily_turnover = close * volume
    # Per-day Amihud impact: |return| / turnover. Guard zero/NaN turnover.
    impact_daily = (
        daily_ret_abs / daily_turnover.replace(0.0, np.nan)
    )
    # Scale so the number is human-readable; the absolute scale is
    # irrelevant downstream because scoring tiers on it per-market.
    illiquidity_impact = last(
        (impact_daily * 1e9).rolling(window=20, min_periods=5).mean()
    )
    range_pct_s = ((high_s - low_s) / close.replace(0.0, np.nan)) * 100.0
    range_pct_20d = last(range_pct_s.rolling(window=20, min_periods=5).mean())
    last20_vol = volume.tail(20)
    zero_volume_days_20d = (
        int((last20_vol.fillna(0) <= 0).sum()) if len(last20_vol) else None
    )

    # Phase 1 additions (new keys only; existing keys unchanged).
    sma20_s = sma(close, 20)
    sma50_s = sma(close, 50)
    obv_s = obv(close, volume)
    ad_s = accum_dist(df)
    cmf_s = cmf(df)
    vwap_s = vwap(df)
    adx_s = adx(df)
    bb_df = bollinger_bands(close)

    last_close = last(close)
    last_volume = last(volume)
    last_atr = last(atr_s)

    # --- Phase 2 support: rolling aggregates legacy category rules need ---
    def roll_mean(series: pd.Series, w: int):
        s = series.rolling(window=w, min_periods=w).mean()
        return last(s)

    prev_close = prev(close)
    prev_volume = prev(volume)
    # Rolling volume means (trailing, excluding NaN warm-up).
    vol_mean_10 = roll_mean(volume, 10)
    vol_mean_20 = roll_mean(volume, 20)
    vol_mean_30 = roll_mean(volume, 30)
    # A/D and OBV 30-day means (for accumulation).
    ad_mean_30 = roll_mean(ad_s, 30)
    obv_mean_30 = roll_mean(obv_s, 30)
    # Short-window vol ratio vol_3/vol_20 (turnaround / silent accumulation).
    vol_mean_3 = roll_mean(volume, 3)
    vol3_over_20 = (
        vol_mean_3 / vol_mean_20
        if (vol_mean_3 is not None and vol_mean_20 not in (None, 0))
        else None
    )
    # OBV change over last 3 bars (smart-money inflow proxy).
    obv_diff_3 = None
    obv_nonan = obv_s.dropna()
    if len(obv_nonan) >= 4:
        obv_diff_3 = float(obv_nonan.iloc[-1] - obv_nonan.iloc[-4])
    # 3-day absolute price change %.
    pct_change_3 = None
    close_nonan = close.dropna()
    if len(close_nonan) >= 4 and close_nonan.iloc[-4] != 0:
        pct_change_3 = abs(
            float(close_nonan.iloc[-1] / close_nonan.iloc[-4] - 1)
        )
    # Latest high (for ARA near-high check).
    last_high = last(df["High"])

    # --- Phase 3 support: support/resistance (rolling min/max, legacy) ---
    low = df["Low"]
    high = df["High"]
    immediate_support = last(low.rolling(window=10, min_periods=1).min())
    immediate_resistance = last(high.rolling(window=10, min_periods=1).max())
    major_support = last(low.rolling(window=50, min_periods=1).min())
    major_resistance = last(high.rolling(window=50, min_periods=1).max())

    return {
        "close": last_close,
        "rsi": last(rsi_s),
        "rsi_prev": prev(rsi_s),
        "ema20": last(ema20_s),
        "ema50": last(ema50_s),
        "ema200": last(ema200_s),
        "sma200": last(sma200_s),
        "roc": last(roc_s),
        "high_52w": last(high_52w_s),
        "avg_value_traded": avg_value_traded,
        "vol_ratio_5_20": vol_ratio_5_20,
        # Phase 11B aliases (additive). avg_value_traded_20d == avg_value_traded;
        # avg_volume_20d == vol_mean_20. New ratio keys for participation.
        "avg_value_traded_20d": avg_value_traded,
        "avg_volume_20d": vol_mean_20_avt,
        "volume_ratio_20d": volume_ratio_20d,
        "value_traded_ratio_20d": value_traded_ratio_20d,
        "macd": last(macd_df["macd"]),
        "macd_signal": last(macd_df["signal"]),
        "macd_hist": last(macd_df["hist"]),
        "macd_hist_prev": prev(macd_df["hist"]),
        "volume_ratio": last(vr_s),
        "atr": last_atr,
        "atr_pct": (last_atr / last_close * 100)
        if (last_atr is not None and last_close not in (None, 0))
        else None,
        # --- Phase 1: new indicator outputs (do not affect scoring yet) ---
        "sma20": last(sma20_s),
        "sma50": last(sma50_s),
        "obv": last(obv_s),
        "obv_prev": prev(obv_s),
        "ad": last(ad_s),
        "ad_prev": prev(ad_s),
        "cmf": last(cmf_s),
        "vwap": last(vwap_s),
        "adx": last(adx_s),
        "bb_upper": last(bb_df["upper"]),
        "bb_middle": last(bb_df["middle"]),
        "bb_lower": last(bb_df["lower"]),
        "volume": last_volume,
        "value_traded": (last_close * last_volume)
        if (last_close is not None and last_volume is not None)
        else None,
        # Microstructure liquidity proxies (order-book quality from OHLCV).
        "illiquidity_impact": illiquidity_impact,
        "range_pct_20d": range_pct_20d,
        "zero_volume_days_20d": zero_volume_days_20d,
        # --- Phase 2 support: rolling aggregates for category rules ---
        "high": last_high,
        "immediate_support": immediate_support,
        "immediate_resistance": immediate_resistance,
        "major_support": major_support,
        "major_resistance": major_resistance,
        "prev_close": prev_close,
        "prev_volume": prev_volume,
        "vol_mean_10": vol_mean_10,
        "vol_mean_20": vol_mean_20,
        "vol_mean_30": vol_mean_30,
        "vol_mean_3": vol_mean_3,
        "vol3_over_20": vol3_over_20,
        "ad_mean_30": ad_mean_30,
        "obv_mean_30": obv_mean_30,
        "obv_diff_3": obv_diff_3,
        "pct_change_3": pct_change_3,
    }
