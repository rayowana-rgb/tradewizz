"""Real screening/analysis engine.

Fetches OHLCV via yfinance, computes indicators, and derives the app's signal /
score / category taxonomy. Every public entry point falls back to the
deterministic mock generators (``mock_data``) if data fetch or computation
fails, so the API never hard-fails on a flaky data source.
"""

from __future__ import annotations

import logging
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Callable, List, Optional

import pandas as pd

from . import backtest as backtest_mod
from . import indicators, mock_data
from .ml import ProfitModel
from .cache import make_cached_fetcher
from .universe import UniverseRepository
from .models import (
    AnalysisResult,
    BacktestResult,
    Market,
    ScreenerCategory,
    ScreenerMatch,
    ScreenerResult,
    SupportResistance,
    WeeklyPrediction,
)

logger = logging.getLogger("tradewiz.engine")

# Screener pagination bounds.
DEFAULT_LIMIT = 50
MAX_LIMIT = 200

# Default liquidity floor for /screen, in legacy IDR (matches bot9's
# MIN_VALUE_IDR = 2B). Scaled per market by `default_min_value_traded`.
DEFAULT_MIN_VALUE_TRADED_IDR = 2_000_000_000


def default_min_value_traded(market: Market) -> float:
    """Per-market default liquidity floor (2B IDR, FX-scaled for HKD/KRW)."""
    if market is Market.HKEX:
        return DEFAULT_MIN_VALUE_TRADED_IDR / 2000.0  # ~1M HKD
    if market in (Market.KOSPI, Market.KOSDAQ):
        return DEFAULT_MIN_VALUE_TRADED_IDR / 12.0  # ~167M KRW
    return float(DEFAULT_MIN_VALUE_TRADED_IDR)  # IDX / default

# Max concurrent per-symbol fetches during /screen (override via env).
_SCREEN_WORKERS = int(os.environ.get("TRADEWIZ_SCREEN_WORKERS", "8"))

# yfinance ticker suffix per market.
MARKET_SUFFIX = {
    Market.IDX: ".JK",
    Market.HKEX: ".HK",
    Market.KOSPI: ".KS",
    Market.KOSDAQ: ".KQ",
}


# Yahoo expects a fixed zero-padded numeric code per market: HKEX uses 4 digits
# (e.g. 02331 -> 2331.HK, 700 -> 0700.HK); KOSPI/KOSDAQ use 6 digits (e.g.
# 5930 -> 005930.KS). IDX uses alphabetic tickers and is left untouched.
_YAHOO_CODE_WIDTH = {
    Market.HKEX: 4,
    Market.KOSPI: 6,
    Market.KOSDAQ: 6,
}


def _normalize_numeric_code(sym: str, width: int) -> str:
    """Normalize a numeric exchange code to Yahoo's expected zero-padded width.

    Strips leading zeros then re-pads to `width` (so 02331 -> 2331, 700 -> 0700
    for width 4; 5930 -> 005930 for width 6). Non-numeric input is returned
    unchanged.
    """
    if not sym.isdigit():
        return sym
    return sym.lstrip("0").zfill(width) or "0".zfill(width)


def yf_symbol(symbol: str, market: Market) -> str:
    """Map a bare symbol + market to a yfinance ticker (idempotent).

    For HKEX/KOSPI/KOSDAQ the numeric code is normalized to Yahoo's expected
    zero-padded width before the suffix is appended. IDX is unchanged.
    """
    sym = symbol.upper().strip()
    suffix = MARKET_SUFFIX[market]
    if sym.endswith(suffix):
        return sym  # idempotent: already a yfinance ticker
    width = _YAHOO_CODE_WIDTH.get(market)
    if width is not None:
        sym = _normalize_numeric_code(sym, width)
    return f"{sym}{suffix}"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# Currency symbol per market for investor-friendly highlight formatting.
_CURRENCY = {
    Market.IDX: "Rp",
    Market.HKEX: "HK$",
    Market.KOSPI: "\u20a9",
    Market.KOSDAQ: "\u20a9",
}


def _currency_symbol(market: Optional[Market]) -> str:
    return _CURRENCY.get(market, "") if market is not None else ""


# Market session metadata for the analysis highlights. Simple schedule only
# (no holiday calendar): Mon-Fri within the local open/close window.
_MARKET_SESSION = {
    # market: (IANA timezone, tz-abbrev, open_hour, close_hour)
    Market.IDX: ("Asia/Jakarta", "WIB", 9, 16),
    Market.HKEX: ("Asia/Hong_Kong", "HKT", 9, 16),
    Market.KOSPI: ("Asia/Seoul", "KST", 9, 16),
    Market.KOSDAQ: ("Asia/Seoul", "KST", 9, 16),
}


def _market_now(market: Optional[Market]) -> datetime:
    """Current time in the market's local timezone (defaults to IDX/Jakarta)."""
    from zoneinfo import ZoneInfo

    tz = _MARKET_SESSION.get(market, _MARKET_SESSION[Market.IDX])[0]
    return datetime.now(ZoneInfo(tz))


# OHLCV cache TTLs. The *latest* candle is volatile while a session is open
# (intraday close keeps moving) and final once closed. Use a short TTL when any
# supported market is open so the latest price stays current; a long TTL when
# all are closed (the last candle won't change). Override via env.
_CACHE_TTL_OPEN = int(os.environ.get("TRADEWIZ_CACHE_TTL_OPEN", "300"))     # 5m
_CACHE_TTL_CLOSED = int(os.environ.get("TRADEWIZ_CACHE_TTL_CLOSED", "21600"))  # 6h


def _any_market_open(now_provider=None) -> bool:
    """True if any supported market is currently in session."""
    for mkt in _MARKET_SESSION:
        now = now_provider(mkt) if now_provider else _market_now(mkt)
        if _is_market_open(mkt, now):
            return True
    return False


def _dynamic_cache_ttl() -> int:
    """Short TTL while any market is open; long TTL when all are closed."""
    return _CACHE_TTL_OPEN if _any_market_open() else _CACHE_TTL_CLOSED


def _is_market_open(market: Optional[Market], now: datetime) -> bool:
    """True if `now` is within a weekday trading session for the market."""
    _, _, open_h, close_h = _MARKET_SESSION.get(
        market, _MARKET_SESSION[Market.IDX]
    )
    if now.weekday() >= 5:  # Saturday=5, Sunday=6
        return False
    open_minutes = open_h * 60
    close_minutes = close_h * 60
    cur_minutes = now.hour * 60 + now.minute
    return open_minutes <= cur_minutes <= close_minutes


def _market_status_lines(
    market: Optional[Market],
    last_data_date: Optional[datetime] = None,
    now: Optional[datetime] = None,
) -> List[str]:
    """Two leading highlight lines: market status + data timestamp.

    `now` is injectable for testing; defaults to the market-local current time.
    """
    tz_abbr = _MARKET_SESSION.get(market, _MARKET_SESSION[Market.IDX])[1]
    current = now if now is not None else _market_now(market)
    if _is_market_open(market, current):
        # Data-freshness check: is the latest candle from today's session?
        latest_is_today = (
            last_data_date is not None
            and last_data_date.date() == current.date()
        )
        if latest_is_today:
            return [
                "Market Status: OPEN",
                "Data Source Status: LIVE SESSION DATA",
                f"Data Timestamp: {current.strftime('%d %b %Y %H:%M')} {tz_abbr}",
            ]
        # Provider still serving a prior session's candle while market is open.
        if last_data_date is not None:
            return [
                "Market Status: OPEN",
                "Data Source Status: PREVIOUS SESSION DATA",
                f"Last Market Data: {last_data_date.strftime('%d %b %Y')}",
            ]
        # No data date available: report open without a freshness claim.
        return [
            "Market Status: OPEN",
            f"Data Timestamp: {current.strftime('%d %b %Y %H:%M')} {tz_abbr}",
        ]
    close_dt = last_data_date if last_data_date is not None else current
    return [
        "Market Status: CLOSED",
        f"Last Market Close: {close_dt.strftime('%d %b %Y')}",
    ]


def _compact(value: float) -> str:
    """Human-readable compact number (e.g. 8.3 Million, 1.45 Billion)."""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return "n/a"
    sign = "-" if v < 0 else ""
    n = abs(v)
    if n >= 1_000_000_000_000:
        return f"{sign}{n / 1_000_000_000_000:.2f} Trillion"
    if n >= 1_000_000_000:
        return f"{sign}{n / 1_000_000_000:.2f} Billion"
    if n >= 1_000_000:
        return f"{sign}{n / 1_000_000:.1f} Million"
    if n >= 1_000:
        return f"{sign}{n / 1_000:.1f} Thousand"
    return f"{sign}{n:,.0f}"


# A fetcher returns an OHLCV DataFrame (columns: Open/High/Low/Close/Volume) or
# raises. Signature: (ticker, period, interval). Injectable so tests can supply
# synthetic data with no network.
Fetcher = Callable[[str, str, str], pd.DataFrame]


# Per-request network timeout for yfinance (seconds). Keeps a slow/blocked data
# source from stalling /screen across a whole universe. Override via env.
_YF_TIMEOUT = float(os.environ.get("TRADEWIZ_YF_TIMEOUT", "8"))

# Browser profile for curl_cffi TLS impersonation. Yahoo's edge WAF blocks the
# default requests/urllib3 (esp. LibreSSL) TLS fingerprint with HTTP 429; a real
# browser JA3 fingerprint passes. Override via TRADEWIZ_YF_IMPERSONATE.
_YF_IMPERSONATE = os.environ.get("TRADEWIZ_YF_IMPERSONATE", "chrome")


def _impersonating_session():
    """A curl_cffi session impersonating a real browser, or None if unavailable.

    yfinance accepts a `session=`; a curl_cffi session with a browser TLS
    fingerprint bypasses Yahoo's fingerprint-based 429 blocking.
    """
    try:
        from curl_cffi import requests as cffi_requests

        return cffi_requests.Session(impersonate=_YF_IMPERSONATE)
    except Exception:  # noqa: BLE001 - fall back to yfinance default session
        return None


def _yf_fetch(ticker: str, period: str = "1y", interval: str = "1d") -> pd.DataFrame:
    import yfinance as yf

    kwargs = dict(
        period=period,
        interval=interval,
        auto_adjust=False,
        progress=False,
        threads=False,
        timeout=_YF_TIMEOUT,
    )
    session = _impersonating_session()
    if session is not None:
        kwargs["session"] = session
    df = yf.download(ticker, **kwargs)
    if df is None or df.empty:
        raise ValueError(f"No data for {ticker}")
    # yfinance may return a column MultiIndex for a single ticker; flatten it.
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    needed = {"Open", "High", "Low", "Close", "Volume"}
    if not needed.issubset(set(df.columns)):
        raise ValueError(f"Missing OHLCV columns for {ticker}: {df.columns}")
    return df


class AnalysisEngine:
    def __init__(
        self,
        fetcher: Optional[Fetcher] = None,
        universe: Optional[UniverseRepository] = None,
        profit_model: Optional["ProfitModel"] = None,
    ):
        # Default: yfinance behind the on-disk OHLCV cache. Use a market-aware
        # TTL so the latest candle refreshes while any session is open (avoids
        # serving a stale intraday close) and is cached long once closed.
        self._fetch = fetcher or make_cached_fetcher(
            _yf_fetch, ttl_seconds=_dynamic_cache_ttl
        )
        self._universe = universe or UniverseRepository()
        self._profit_model = profit_model if profit_model is not None \
            else ProfitModel()

    # -- categories --------------------------------------------------------

    def categorize(
        self, ind: dict, market: Optional[Market] = None
    ) -> List[ScreenerCategory]:
        """Map indicator values onto the app's category taxonomy.

        Phase 2: accumulation, accumulation_silent, pullback, frequently_traded,
        short_candidate, turnaround_multibagger and ara_hunter use rules ported
        faithfully from the legacy bot (OBV / A-D / CMF / SMA20-50 / VWAP /
        rolling-volume based). bullish/bearish/scalping remain the prior
        approximations (migrated in a later step). Liquidity thresholds are
        scaled per market currency via `_value_floor`.
        """
        cats: List[ScreenerCategory] = []
        close = ind.get("close")
        rsi = ind.get("rsi")
        ema20 = ind.get("ema20")
        ema50 = ind.get("ema50")
        sma20 = ind.get("sma20")
        sma50 = ind.get("sma50")
        sma200 = ind.get("sma200")
        macd = ind.get("macd")
        macd_signal = ind.get("macd_signal")
        macd_hist = ind.get("macd_hist")
        atr_pct = ind.get("atr_pct")
        vr = ind.get("volume_ratio")
        cmf = ind.get("cmf")
        obv = ind.get("obv")
        obv_prev = ind.get("obv_prev")
        ad = ind.get("ad")
        ad_prev = ind.get("ad_prev")
        ad_mean_30 = ind.get("ad_mean_30")
        obv_mean_30 = ind.get("obv_mean_30")
        volume = ind.get("volume")
        prev_volume = ind.get("prev_volume")
        prev_close = ind.get("prev_close")
        high = ind.get("high")
        value_traded = ind.get("value_traded")
        vol_mean_10 = ind.get("vol_mean_10")
        vol_mean_20 = ind.get("vol_mean_20")
        vol_mean_30 = ind.get("vol_mean_30")
        vol3_over_20 = ind.get("vol3_over_20")
        obv_diff_3 = ind.get("obv_diff_3")
        pct_change_3 = ind.get("pct_change_3")

        def has(*vals) -> bool:
            return all(v is not None for v in vals)

        def gt(a, b) -> bool:
            return a is not None and b is not None and a > b

        # Per-market liquidity floors (legacy used IDR; scale for HKD/KRW).
        v500m = self._value_floor(market, 500_000_000)
        v5b = self._value_floor(market, 5_000_000_000)
        v10b = self._value_floor(market, 10_000_000_000)
        cheap = self._cheap_price(market)  # legacy <250/<300 IDR thresholds

        # --- bullish/bearish/scalping: unchanged approximations (later) ---
        if gt(ema20, ema50) and gt(close, ema20):
            cats.append(ScreenerCategory.bullish)
        if gt(ema50, ema20) and gt(ema20, close):
            cats.append(ScreenerCategory.bearish)
        if atr_pct is not None and atr_pct >= 4.0:
            cats.append(ScreenerCategory.scalping)

        # --- accumulation (legacy screen_accumulation) ---
        # Strong A/D+OBV+volume vs 30d, price not exploded (<SMA50*1.15),
        # value_traded >= 10B (scaled).
        if (
            has(ad, ad_mean_30, obv, obv_mean_30, volume, vol_mean_30,
                close, sma50, value_traded)
            and ad > ad_mean_30 * 1.1
            and obv > obv_mean_30
            and volume > vol_mean_30 * 1.2
            and close < sma50 * 1.15
            and value_traded >= v10b
        ):
            cats.append(ScreenerCategory.accumulation)

        # --- accumulation_silent (legacy silent accumulation) ---
        # Cheap price, vol_3/vol_20 > 2, |3d %chg| < 2%, CMF>0, OBV 3d up.
        if (
            has(close, vol3_over_20, pct_change_3, cmf, obv_diff_3)
            and close < cheap
            and vol3_over_20 > 2
            and pct_change_3 < 0.02
            and cmf > 0
            and obv_diff_3 > 0
        ):
            cats.append(ScreenerCategory.accumulation_silent)

        # --- pullback (legacy screen_pullback; requires ALL) ---
        if (
            has(sma50, sma200, close, sma20, rsi, macd, macd_signal,
                volume, prev_volume)
            and sma50 > sma200
            and close > sma200
            and close < sma20
            and 40 < rsi < 60
            and macd > 0
            and macd < macd_signal
            and volume < prev_volume
        ):
            cats.append(ScreenerCategory.pullback)

        # --- turnaround_multibagger (legacy inline) ---
        # value>=500M, cheap, Close>MA20>MA50, vol_3/vol_20>1, CMF>0,
        # OBV 3d up, 30<RSI<60.
        if (
            has(value_traded, close, sma20, sma50, vol3_over_20, cmf,
                obv_diff_3, rsi)
            and value_traded >= v500m
            and close < cheap
            and close > sma20
            and sma20 > sma50
            and vol3_over_20 > 1
            and cmf > 0
            and obv_diff_3 > 0
            and 30 < rsi < 60
        ):
            cats.append(ScreenerCategory.turnaround_multibagger)

        # --- ara_hunter (legacy inline) ---
        # Near auto-reject: +6% vs prev, near high, vol>10d*3, RSI>70,
        # MACD>Signal, A/D & OBV rising, Close>SMA20, value>=5B.
        if (
            has(close, prev_close, high, volume, vol_mean_10, rsi, macd,
                macd_signal, ad, ad_prev, obv, obv_prev, sma20, value_traded)
            and close >= prev_close * 1.06
            and close >= high * 0.98
            and volume > vol_mean_10 * 3
            and rsi > 70
            and macd > macd_signal
            and ad > ad_prev
            and obv > obv_prev
            and close > sma20
            and value_traded >= v5b
        ):
            cats.append(ScreenerCategory.ara_hunter)

        # --- frequently_traded (legacy inline) ---
        # Volume > 20d mean * 2 AND value_traded > 10B (scaled).
        if (
            has(volume, vol_mean_20, value_traded)
            and volume > vol_mean_20 * 2
            and value_traded > v10b
        ):
            cats.append(ScreenerCategory.frequently_traded)

        # --- short_candidate (legacy screen_short_candidates) ---
        # RSI>70 & falling, MACD<Signal, hist<0, Close<SMA20, vol>10d*1.5,
        # OBV & A/D falling.
        if (
            has(rsi, ind.get("rsi_prev"), macd, macd_signal, macd_hist,
                close, sma20, volume, vol_mean_10, obv, obv_prev, ad, ad_prev)
            and rsi > 70
            and rsi < ind.get("rsi_prev")
            and macd < macd_signal
            and macd_hist < 0
            and close < sma20
            and volume > vol_mean_10 * 1.5
            and obv < obv_prev
            and ad < ad_prev
        ):
            cats.append(ScreenerCategory.short_candidate)

        return cats

    @staticmethod
    def _value_floor(market: Optional[Market], idr_amount: float) -> float:
        """Scale a legacy IDR liquidity threshold to the market's currency.

        Rough FX so HKD/KRW markets don't require IDR-sized turnover. IDX keeps
        the original IDR figures.
        """
        # Approx value of 1 unit of currency in IDR (order-of-magnitude).
        # 1 HKD ~ 2000 IDR, 1 KRW ~ 12 IDR.
        if market in (Market.HKEX,):
            return idr_amount / 2000.0
        if market in (Market.KOSPI, Market.KOSDAQ):
            return idr_amount / 12.0
        return idr_amount  # IDX / default: legacy IDR amounts

    @staticmethod
    def _cheap_price(market: Optional[Market]) -> float:
        """Legacy 'cheap' price ceiling (<250-300 IDR) scaled per market."""
        if market in (Market.HKEX,):
            return 5.0  # ~ small-cap HKD
        if market in (Market.KOSPI, Market.KOSDAQ):
            return 5000.0  # KRW
        return 300.0  # IDX / default

    def _signal_and_score(self, ind: dict, cats: List[ScreenerCategory]):
        """Derive a BUY/HOLD/SELL signal and a 0..100 conviction score."""
        score = 50.0
        rsi = ind.get("rsi")
        close = ind.get("close")
        ema20 = ind.get("ema20")
        ema50 = ind.get("ema50")
        sma200 = ind.get("sma200")
        macd_hist = ind.get("macd_hist")

        if ema20 is not None and ema50 is not None:
            score += 12 if ema20 > ema50 else -12
        if close is not None and sma200 is not None:
            score += 10 if close > sma200 else -10
        if macd_hist is not None:
            score += 8 if macd_hist > 0 else -8
        if rsi is not None:
            if rsi < 30:
                score += 6  # oversold bounce potential
            elif rsi > 70:
                score -= 6  # overbought
        if ScreenerCategory.bullish in cats:
            score += 6
        if ScreenerCategory.bearish in cats:
            score -= 6

        score = max(0.0, min(100.0, score))
        if score >= 66:
            signal = "BUY"
        elif score >= 40:
            signal = "HOLD"
        else:
            signal = "SELL"
        return signal, round(score, 1)

    def _highlights(
        self,
        ind: dict,
        market: Optional[Market] = None,
        last_data_date: Optional["datetime"] = None,
    ) -> List[str]:
        """Investor-friendly market metrics for the analysis card.

        Replaces the raw technical readouts (RSI/EMA/SMA/MACD) with
        price/volume/turnover that normal investors can interpret, prefixed by
        market status + data timestamp. Does not affect scoring, signals,
        categories, ML, or backtest.
        """
        cur = _currency_symbol(market)

        def money(v) -> str:
            return f"{cur}{_compact(v)}" if v is not None else "n/a"

        def count(v) -> str:
            return _compact(v) if v is not None else "n/a"

        def price(v) -> str:
            return f"{cur}{v:,.2f}" if v is not None else "n/a"

        def ratio(v) -> str:
            return f"{v:.2f}x" if v is not None else "n/a"

        def pct(v) -> str:
            return f"{v:.2f}%" if v is not None else "n/a"

        return _market_status_lines(market, last_data_date) + [
            f"Current Price: {price(ind.get('close'))}",
            f"20-Day Average Price: {price(ind.get('sma20'))}",
            f"Today's Volume: {count(ind.get('volume'))}",
            f"20-Day Average Volume: {count(ind.get('vol_mean_20'))}",
            f"Value Traded Today: {money(ind.get('value_traded'))}",
            f"Volume Ratio: {ratio(ind.get('volume_ratio'))}",
            f"ATR: {pct(ind.get('atr_pct'))}",
        ]

    # -- Phase 3: signal confirmation / S-R / trailing stop ---------------

    def _buy_reasons(self, ind: dict) -> List[str]:
        """Confirmation reasons (ported from legacy analyze_screened_stocks).

        Uses OBV / A-D / CMF / VWAP / MACD / RSI / volume confirmation.
        """
        reasons: List[str] = []
        macd = ind.get("macd")
        macd_signal = ind.get("macd_signal")
        rsi = ind.get("rsi")
        rsi_prev = ind.get("rsi_prev")
        ad = ind.get("ad")
        ad_prev = ind.get("ad_prev")
        obv = ind.get("obv")
        obv_prev = ind.get("obv_prev")
        cmf = ind.get("cmf")
        volume = ind.get("volume")
        vol_mean_10 = ind.get("vol_mean_10")
        close = ind.get("close")
        vwap = ind.get("vwap")

        if macd is not None and macd_signal is not None and macd > macd_signal:
            reasons.append("MACD bullish")
        if rsi is not None and rsi_prev is not None and rsi > rsi_prev:
            reasons.append("RSI rising")
        if ad is not None and ad_prev is not None and ad > ad_prev:
            reasons.append("A/D rising")
        if obv is not None and obv_prev is not None and obv > obv_prev:
            reasons.append("OBV rising")
        if cmf is not None and cmf > 0:
            reasons.append("Positive money flow (CMF)")
        if (
            volume is not None
            and vol_mean_10 is not None
            and volume > vol_mean_10 * 1.5
        ):
            reasons.append("Volume spike")
        if close is not None and vwap is not None and close > vwap:
            reasons.append("Above VWAP")
        return reasons

    @staticmethod
    def _support_resistance(ind: dict) -> Optional[SupportResistance]:
        keys = (
            "immediate_support", "immediate_resistance",
            "major_support", "major_resistance",
        )
        if all(ind.get(k) is None for k in keys):
            return None
        return SupportResistance(
            immediate_support=ind.get("immediate_support"),
            immediate_resistance=ind.get("immediate_resistance"),
            major_support=ind.get("major_support"),
            major_resistance=ind.get("major_resistance"),
        )

    @staticmethod
    def _trailing_stop(ind: dict, cats: List[ScreenerCategory]):
        """ADX-banded trailing stop % + price (legacy: tighter for scalping)."""
        close = ind.get("close")
        if close is None:
            return None, None
        adx = ind.get("adx")
        adx = adx if adx is not None else 20.0
        is_scalping = ScreenerCategory.scalping in cats
        if is_scalping:
            pct = 2 if adx < 20 else 3 if adx < 30 else 4 if adx < 40 else 5
        else:
            pct = 5 if adx < 20 else 7 if adx < 30 else 8 if adx < 40 else 10
        price = round(close * (1 - pct / 100.0), 2)
        return float(pct), price

    @staticmethod
    def _profit_probability_placeholder(score: float) -> float:
        """Deterministic 0..1 placeholder until the ML model lands (Phase 4).

        Derived from the conviction score so it is monotonic and stable.
        """
        return round(max(0.0, min(1.0, score / 100.0)), 4)

    @staticmethod
    def _recommendation(signal: str, cats: List[ScreenerCategory]) -> str:
        tag = cats[0].value if cats else "signal"
        if signal == "BUY":
            return f"BUY — confirmed by {tag}"
        if signal == "SELL":
            return f"SELL / avoid — weak {tag} setup"
        return "HOLD — no clear buy/sell signal yet"

    # -- public API --------------------------------------------------------

    def analyze(self, symbol: str, market: Market) -> AnalysisResult:
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "1y", "1d")
            ind = indicators.compute_all(df)
            if ind.get("close") is None:
                raise ValueError("insufficient data")
            cats = self.categorize(ind, market)
            signal, score = self._signal_and_score(ind, cats)
            tags = ", ".join(c.value for c in cats) or "none"
            ts_pct, ts_price = self._trailing_stop(ind, cats)
            # Last completed bar's date (for the CLOSED "Last Market Close").
            last_date = None
            try:
                last_date = df.index[-1].to_pydatetime()
            except Exception:  # noqa: BLE001 - date is best-effort
                last_date = None
            # Real RandomForest profit probability; placeholder if untrainable.
            profit_prob = self._profit_model.probability(
                df, market.value, symbol.upper()
            )
            if profit_prob is None:
                profit_prob = self._profit_probability_placeholder(score)
            return AnalysisResult(
                symbol=symbol.upper(),
                market=market,
                signal=signal,
                score=score,
                summary=(
                    f"{symbol.upper()} ({ticker}) on {market.value}: {signal} "
                    f"(score {score}). Tags: {tags}."
                ),
                highlights=self._highlights(ind, market, last_date),
                generated_at=_now_iso(),
                # --- Phase 3 additive fields ---
                recommendation=self._recommendation(signal, cats),
                buy_reasons=self._buy_reasons(ind),
                support_resistance=self._support_resistance(ind),
                trailing_stop_percent=ts_pct,
                trailing_stop_price=ts_price,
                profit_probability=profit_prob,
            )
        except Exception as exc:  # noqa: BLE001 - intentional safe fallback
            logger.warning("analyze fell back to mock for %s: %s", ticker, exc)
            return mock_data.mock_analyze(symbol, market)

    def predict_weekly(self, symbol: str, market: Market) -> WeeklyPrediction:
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "6mo", "1d")
            ind = indicators.compute_all(df)
            close = ind.get("close")
            ema20 = ind.get("ema20")
            macd_hist = ind.get("macd_hist")
            atr_pct = ind.get("atr_pct")
            if close is None:
                raise ValueError("insufficient data")

            up_votes = 0
            if ema20 is not None and close > ema20:
                up_votes += 1
            if macd_hist is not None and macd_hist > 0:
                up_votes += 1
            rsi = ind.get("rsi")
            if rsi is not None and rsi > 50:
                up_votes += 1

            if up_votes >= 2:
                direction = "UP"
            elif up_votes == 0:
                direction = "DOWN"
            else:
                direction = "FLAT"

            # Expected move ~ weekly drift proxied by ATR% (bounded).
            base = atr_pct if atr_pct is not None else 1.0
            sign = 1 if direction == "UP" else (-1 if direction == "DOWN" else 0)
            expected = round(sign * min(base, 8.0), 2)
            confidence = round(0.4 + 0.2 * up_votes, 2)  # 0.4..1.0

            return WeeklyPrediction(
                symbol=symbol.upper(),
                direction=direction,
                expected_change_percent=expected,
                confidence=min(confidence, 1.0),
                rationale=(
                    f"{up_votes}/3 bullish factors (EMA20, MACD hist, RSI). "
                    f"Volatility (ATR%) {base:.2f}."
                ),
            )
        except Exception as exc:  # noqa: BLE001
            logger.warning("predict fell back to mock for %s: %s", ticker, exc)
            return mock_data.mock_predict_weekly(symbol)

    def backtest(
        self,
        symbol: str,
        market: Market,
        signal_type: str = backtest_mod.DEFAULT_SIGNAL_TYPE,
        forward_days: int = backtest_mod.DEFAULT_FORWARD_DAYS,
    ) -> BacktestResult:
        """Backtest a historical buy-signal rule over the symbol's history.

        Returns zeroed stats (not an error) when data is unavailable, so the
        endpoint stays 200 and contract-stable.
        """
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "1y", "1d")
            if df is None or df.empty:
                raise ValueError("no data")
            stats = backtest_mod.run_backtest(df, signal_type, forward_days)
        except Exception as exc:  # noqa: BLE001 - safe, contract-stable
            logger.warning("backtest fell back to empty for %s: %s", ticker, exc)
            stats = {
                "total_signals": 0, "total_wins": 0, "total_losses": 0,
                "win_rate": 0.0, "average_return": 0.0,
                "profit_factor": 0.0, "max_drawdown": 0.0,
            }
        return BacktestResult(
            symbol=symbol.upper(),
            market=market,
            signal_type=signal_type,
            forward_days=forward_days,
            generated_at=_now_iso(),
            **stats,
        )

    def screen(
        self,
        market: Market,
        symbols: Optional[List[str]] = None,
        limit: int = DEFAULT_LIMIT,
        min_score: float = 0.0,
        categories: Optional[List[ScreenerCategory]] = None,
        min_value_traded: float = 0.0,
    ) -> ScreenerResult:
        """Screen a market's symbol universe (or an explicit symbol list).

        Resolution order:
          1. explicit ``symbols`` argument, if given;
          2. the market's configured universe (CSV/Excel);
          3. mock screener output if neither yields a usable universe.

        Results are filtered by ``min_score`` and ``categories`` (a match must
        carry at least one requested category), sorted by score desc then
        change_percent desc, and truncated to ``limit`` (bounded to MAX_LIMIT).
        """
        names: dict = {}
        if not symbols:
            symbols = self._universe.symbols(market)
            names = self._universe.names(market)

        if not symbols:
            return self._finalize(
                mock_data.mock_screen(market), limit, min_score, categories,
                min_value_traded,
            )

        # Screen symbols concurrently so a slow data source doesn't serialize
        # N timeouts. The cache's single-flight guard keeps this safe; failures
        # fall back to deterministic per-symbol mock data (never dropped).
        workers = min(len(symbols), _SCREEN_WORKERS)
        matches: List[ScreenerMatch] = []
        if workers <= 1:
            matches = [self._screen_one(s, market, names) for s in symbols]
        else:
            with ThreadPoolExecutor(max_workers=workers) as pool:
                matches = list(
                    pool.map(
                        lambda s: self._screen_one(s, market, names), symbols
                    )
                )

        if not matches:
            return self._finalize(
                mock_data.mock_screen(market), limit, min_score, categories,
                min_value_traded,
            )

        result = ScreenerResult(
            market=market, matches=matches, generated_at=_now_iso()
        )
        return self._finalize(
            result, limit, min_score, categories, min_value_traded
        )

    def _screen_one(
        self, sym: str, market: Market, names: dict
    ) -> ScreenerMatch:
        """Screen a single symbol; deterministic mock fallback on any failure."""
        ticker = yf_symbol(sym, market)
        try:
            df = self._fetch(ticker, "1y", "1d")
            ind = indicators.compute_all(df)
            if ind.get("close") is None:
                raise ValueError("insufficient data")
            cats = self.categorize(ind, market)
            signal, score = self._signal_and_score(ind, cats)
            change_pct = _daily_change_pct(df)
            return ScreenerMatch(
                symbol=sym.upper(),
                name=names.get(sym.upper(), sym.upper()),
                score=score,
                signal=signal,
                price=round(ind["close"], 2),
                change_percent=round(change_pct, 2),
                categories=cats,
                value_traded=round(ind.get("value_traded") or 0.0, 2),
            )
        except Exception as exc:  # noqa: BLE001
            # Keep the universe fully populated; response stays 200 "live".
            logger.warning("screen mock-fallback for %s: %s", ticker, exc)
            return mock_data.mock_screener_match(
                sym, market, names.get(sym.upper(), "")
            )

    @staticmethod
    def _finalize(
        result: ScreenerResult,
        limit: int,
        min_score: float,
        categories: Optional[List[ScreenerCategory]],
        min_value_traded: float = 0.0,
    ) -> ScreenerResult:
        """Filter, sort, and paginate.

        Filters: ``min_score``, ``categories`` (match must carry one), and
        ``min_value_traded`` (liquidity floor). Sort: score desc, then
        value_traded desc (liquidity tiebreaker), then change_percent desc.
        """
        limit = max(1, min(int(limit), MAX_LIMIT))
        wanted = set(categories or [])

        matches = [
            m
            for m in result.matches
            if m.score >= min_score
            and m.value_traded >= min_value_traded
            and (not wanted or wanted.intersection(m.categories))
        ]
        matches.sort(
            key=lambda m: (m.score, m.value_traded, m.change_percent),
            reverse=True,
        )
        total = len(matches)  # filtered count BEFORE applying the limit
        result.matches = matches[:limit]
        result.total_count = total
        result.returned_count = len(result.matches)
        result.limit = limit
        result.min_score = min_score
        result.categories = list(categories or [])
        return result


def _daily_change_pct(df: pd.DataFrame) -> float:
    close = df["Close"].dropna()
    if len(close) < 2:
        return 0.0
    prev, last = float(close.iloc[-2]), float(close.iloc[-1])
    return 0.0 if prev == 0 else (last - prev) / prev * 100
