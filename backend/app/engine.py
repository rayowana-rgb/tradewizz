"""Real screening/analysis engine.

Fetches OHLCV via yfinance, computes indicators, and derives the app's signal /
score / category taxonomy. Every public entry point falls back to the
deterministic mock generators (``mock_data``) if data fetch or computation
fails, so the API never hard-fails on a flaky data source.
"""

from __future__ import annotations

import logging
import os
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from typing import Callable, List, Optional

import pandas as pd

from . import backtest as backtest_mod
from . import explore, indicators, mock_data, scoring
from .scoring import MarketContext
from .ml import ProfitModel
from .cache import make_cached_fetcher
from .market_config import idr_per_unit as _idr_per_unit
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
    """Per-market default liquidity floor (2B IDR, FX-scaled to local currency).

    The legacy IDR floor is divided by the market's ``idr_per_unit`` (single
    source of truth in ``market_config``) so every market gets a sane
    local-currency threshold instead of an IDR-sized one. IDX (idr_per_unit=1)
    keeps the original 2B figure; e.g. US -> 2e9/16000 ~= 125k USD,
    JPY -> 2e9/105 ~= 19M JPY, SGD -> 2e9/12000 ~= 167k SGD.
    """
    return DEFAULT_MIN_VALUE_TRADED_IDR / _idr_per_unit(market)

# Max concurrent per-symbol fetches during /screen (override via env).
#
# Lowered from 8 -> 4. Eight workers with no pacing fired hundreds of Yahoo
# requests within seconds during a snapshot rebuild and tripped Yahoo's per-IP
# 429 throttle, so a chunk of the universe failed every rebuild and total_count
# shrank (e.g. 288 -> 113). Since the market-close snapshot is now built only
# ONCE per trading day, a slightly slower-but-complete rebuild is the right
# trade-off. Tune via TRADEWIZ_SCREEN_WORKERS.
_SCREEN_WORKERS = int(os.environ.get("TRADEWIZ_SCREEN_WORKERS", "4"))

# --- Anti-rate-limit (HTTP 429) controls for yfinance fetches. ---
# Retries on a 429 / transient fetch failure, with exponential backoff +
# jitter (and honoring a Retry-After header when Yahoo sends one). A symbol
# that merely got throttled is recovered instead of being dropped to mock.
_YF_MAX_RETRIES = int(os.environ.get("TRADEWIZ_YF_MAX_RETRIES", "3"))
# Base backoff seconds; delay = base * 2**attempt, capped, plus jitter.
_YF_BACKOFF_BASE = float(os.environ.get("TRADEWIZ_YF_BACKOFF_BASE", "0.75"))
_YF_BACKOFF_MAX = float(os.environ.get("TRADEWIZ_YF_BACKOFF_MAX", "8.0"))
# Small random pre-request pause (seconds, 0..N) spreads concurrent worker
# bursts so they don't hit Yahoo in lockstep. Set 0 to disable.
_YF_JITTER_MAX = float(os.environ.get("TRADEWIZ_YF_JITTER_MAX", "0.35"))

# Phase 3: blend the optional RandomForest win-probability into the headline
# score (final = 0.7*technical + 0.3*100*win_prob). OFF by default because a
# thin per-symbol classifier is noisy; the deterministic multi-factor technical
# score is the headline and `profit_probability` is still reported separately.
# Enable with TRADEWIZ_ML_BLEND=1 once a robust cross-sectional model exists.
_ML_BLEND = os.environ.get("TRADEWIZ_ML_BLEND", "0") not in ("0", "", "false", "False")

# yfinance ticker suffix per market. Derived from the single source of truth
# (market_config) so adding a market needs only one table edit. US -> "".
from .market_config import MARKET_CONFIGS as _MARKET_CONFIGS  # noqa: E402

MARKET_SUFFIX = {m: cfg.yahoo_suffix for m, cfg in _MARKET_CONFIGS.items()}


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


# A SINGLE shared curl_cffi session, lazily created and reused across all
# downloads. Previously a new Session was created on EVERY _yf_download call and
# never closed; each curl_cffi Session owns a libcurl handle with its own
# resolver thread(s). During a 956-symbol screen hundreds of un-closed sessions
# piled up -> the host ran out of thread slots (kern.maxprocperuid) and DNS
# resolution failed with "getaddrinfo() thread failed to start", which wedged
# the whole server. Reusing one session keeps thread usage flat and bounded.
_SESSION_LOCK = threading.Lock()
_SHARED_SESSION = None
_SESSION_INIT_TRIED = False


def _impersonating_session():
    """A SHARED curl_cffi session impersonating a real browser, or None.

    yfinance accepts a `session=`; a curl_cffi session with a browser TLS
    fingerprint bypasses Yahoo's fingerprint-based 429 blocking. The session is
    created once and reused (curl_cffi sessions are safe to share across
    threads) so per-symbol fetches don't churn resolver threads.
    """
    global _SHARED_SESSION, _SESSION_INIT_TRIED
    if _SHARED_SESSION is not None:
        return _SHARED_SESSION
    with _SESSION_LOCK:
        if _SHARED_SESSION is not None:
            return _SHARED_SESSION
        if _SESSION_INIT_TRIED:
            # Creation already failed once; don't retry on every call.
            return None
        _SESSION_INIT_TRIED = True
        try:
            from curl_cffi import requests as cffi_requests

            _SHARED_SESSION = cffi_requests.Session(impersonate=_YF_IMPERSONATE)
        except Exception:  # noqa: BLE001 - fall back to yfinance default session
            _SHARED_SESSION = None
        return _SHARED_SESSION


def _is_rate_limited(exc: BaseException) -> bool:
    """True if an exception looks like a Yahoo rate-limit / transient throttle.

    yfinance surfaces 429s in different shapes across versions (a custom
    ``YFRateLimitError``, an HTTPError with status 429, or just a message), so
    we sniff both the class name and the text rather than importing a specific
    exception type.
    """
    name = type(exc).__name__.lower()
    if "ratelimit" in name or "toomanyrequests" in name:
        return True
    status = getattr(getattr(exc, "response", None), "status_code", None)
    if status == 429:
        return True
    text = str(exc).lower()
    return ("429" in text) or ("too many requests" in text) or ("rate limit" in text)


def _retry_after_seconds(exc: BaseException) -> Optional[float]:
    """Honor a server ``Retry-After`` header (seconds) when present."""
    resp = getattr(exc, "response", None)
    headers = getattr(resp, "headers", None)
    if not headers:
        return None
    try:
        raw = headers.get("Retry-After")
        if raw is None:
            return None
        return float(str(raw).strip())
    except (TypeError, ValueError):
        return None


def _yf_download(ticker: str, period: str, interval: str) -> pd.DataFrame:
    """Single raw yfinance download (no retry). Raises on empty/failure."""
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
    return df


def _with_yf_retry(fetch_one, *, label: str):
    """Run ``fetch_one()`` with jitter + retry/backoff on Yahoo rate limits.

    Shared by the screener's strict OHLCV fetch and the market-index fetch so
    both recover from a transient 429 instead of dropping the symbol. A small
    pre-request jitter spreads concurrent worker bursts; on a 429 we back off
    exponentially (with jitter, honoring ``Retry-After``) and retry. Non-429
    errors (e.g. delisted) are NOT retried and propagate immediately to the
    caller's fallback.
    """
    if _YF_JITTER_MAX > 0:
        time.sleep(random.uniform(0, _YF_JITTER_MAX))

    last_exc: Optional[BaseException] = None
    for attempt in range(_YF_MAX_RETRIES + 1):
        try:
            return fetch_one()
        except Exception as exc:  # noqa: BLE001 - classify then maybe retry
            last_exc = exc
            if attempt >= _YF_MAX_RETRIES or not _is_rate_limited(exc):
                raise
            delay = min(_YF_BACKOFF_BASE * (2 ** attempt), _YF_BACKOFF_MAX)
            retry_after = _retry_after_seconds(exc)
            if retry_after is not None:
                delay = max(delay, min(retry_after, _YF_BACKOFF_MAX))
            delay += random.uniform(0, _YF_BACKOFF_BASE)
            logger.info(
                "yfinance 429/throttle for %s (attempt %d/%d); backing off %.2fs",
                label, attempt + 1, _YF_MAX_RETRIES, delay,
            )
            time.sleep(delay)
    # pragma: no cover - loop always returns or raises
    raise last_exc if last_exc else ValueError(f"No data for {label}")


def _yf_fetch(ticker: str, period: str = "1y", interval: str = "1d") -> pd.DataFrame:
    df = _with_yf_retry(
        lambda: _yf_download(ticker, period, interval), label=ticker
    )

    needed = {"Open", "High", "Low", "Close", "Volume"}
    # yfinance returns a column MultiIndex even for a single ticker. The level
    # order varies by version: it can be (field, ticker) OR (ticker, field).
    # Naively flattening with get_level_values(0) can therefore (a) pick the
    # ticker level by mistake, or (b) leave DUPLICATE field columns when more
    # than one ticker leaks into the frame. Either way `df["Close"]` then
    # returns a 2-D slice and the wrong ticker's price is read (the BBCA/BBRI/
    # ASII "all 1010" cache-corruption bug). Resolve the field level robustly
    # and isolate exactly THIS ticker.
    if isinstance(df.columns, pd.MultiIndex):
        field_level = None
        for lvl in range(df.columns.nlevels):
            values = set(df.columns.get_level_values(lvl))
            if needed.issubset(values):
                field_level = lvl
                break
        if field_level is None:
            raise ValueError(f"Missing OHLCV columns for {ticker}: {df.columns}")
        ticker_level = 1 - field_level if df.columns.nlevels == 2 else None
        # If a ticker level exists, slice to the requested ticker only so a
        # multi-ticker frame can never bleed another symbol's prices in.
        if ticker_level is not None:
            tickers = list(dict.fromkeys(df.columns.get_level_values(ticker_level)))
            want = ticker.upper()
            chosen = next((t for t in tickers if str(t).upper() == want), None)
            if chosen is None and len(tickers) == 1:
                chosen = tickers[0]
            if chosen is None:
                raise ValueError(
                    f"{ticker} not found in returned frame {tickers}"
                )
            df = df.xs(chosen, axis=1, level=ticker_level)
            if isinstance(df.columns, pd.MultiIndex):
                df.columns = df.columns.get_level_values(0)
        else:
            df.columns = df.columns.get_level_values(field_level)
    # Guard against any residual duplicate field columns.
    if df.columns.duplicated().any():
        df = df.loc[:, ~df.columns.duplicated()]
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
        # Lazy per-market index context (regime + 3m index return) cache. Keyed
        # by market; refreshed when the cached index fetch returns new data.
        self._index_ctx_cache: dict = {}
        # Phase F: last liquidity-cap outcome from _signal_and_score (so the
        # immediate caller — analyze()/screener — can surface it).
        self._last_liquidity_illiquid: bool = False
        self._last_liquidity_reason: Optional[str] = None

    # -- market context (relative strength + regime) ----------------------

    @staticmethod
    def _period_return(close: pd.Series, lookback: int) -> Optional[float]:
        """Fractional return over the last `lookback` bars (e.g. ~63 = 3m)."""
        c = close.dropna()
        if len(c) <= lookback:
            return None
        past = float(c.iloc[-1 - lookback])
        latest = float(c.iloc[-1])
        if past == 0:
            return None
        return latest / past - 1.0

    def _index_context(self, market: Market) -> tuple:
        """(index_return_3m, regime) for `market`, cached. Best-effort.

        Fetches the market's benchmark index OHLCV via the same cached fetcher,
        derives the 3-month index return and the EMA50/EMA200 regime. Any
        failure (no index symbol, fetch error, short history) yields
        ``(None, None)`` so relative-strength / regime fall back to neutral.
        """
        if market in self._index_ctx_cache:
            return self._index_ctx_cache[market]
        result = (None, None)
        try:
            from .market.service import INDEX_BY_MARKET

            spec = INDEX_BY_MARKET.get(market)
            if spec is not None:
                idf = self._fetch(spec.symbol, "1y", "1d")
                if idf is not None and not idf.empty and "Close" in idf:
                    iclose = idf["Close"].dropna()
                    idx_ret_3m = self._period_return(iclose, 63)
                    ema50 = indicators.ema(iclose, 50)
                    ema200 = indicators.ema(iclose, 200)
                    regime = None
                    e50 = ema50.dropna()
                    e200 = ema200.dropna()
                    if not e50.empty and not e200.empty:
                        regime = (
                            "bull" if float(e50.iloc[-1]) >= float(e200.iloc[-1])
                            else "bear"
                        )
                    result = (idx_ret_3m, regime)
        except Exception as exc:  # noqa: BLE001 - context is best-effort
            logger.debug("index context unavailable for %s: %s", market, exc)
        self._index_ctx_cache[market] = result
        return result

    def _market_context(
        self, df: pd.DataFrame, market: Market
    ) -> MarketContext:
        """Build the scoring MarketContext for a single stock."""
        idx_ret_3m, regime = self._index_context(market)
        rs_value = None
        try:
            stock_ret_3m = self._period_return(df["Close"], 63)
            if stock_ret_3m is not None and idx_ret_3m is not None:
                rs_value = stock_ret_3m - idx_ret_3m
        except Exception:  # noqa: BLE001 - RS is best-effort
            rs_value = None
        return MarketContext(rs_value=rs_value, regime=regime)

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

        Divides the IDR amount by the market's ``idr_per_unit`` (single source
        of truth in ``market_config``) so no market is gated by an IDR-sized
        turnover floor. IDX (idr_per_unit=1) keeps the original IDR figures;
        e.g. HKEX -> /2000, KOSPI/KOSDAQ -> /12, US -> /16000, JPY -> /105,
        SGD -> /12000.
        """
        if market is None:
            return idr_amount  # default: legacy IDR amounts
        return idr_amount / _idr_per_unit(market)

    # Legacy hand-tuned 'cheap' price ceilings (in local currency) for the
    # original markets. Kept as explicit overrides so existing IDX/HKEX/KRW
    # behavior is unchanged; other markets derive the ceiling from the same
    # FX-scaling table (idr_per_unit) used by the value/liquidity floors.
    _CHEAP_PRICE_BASE_IDR = 300.0  # IDX legacy <250-300 IDR ceiling.
    _CHEAP_PRICE_OVERRIDE = {
        Market.IDX: 300.0,   # legacy IDR
        Market.HKEX: 5.0,    # ~ small-cap HKD
        Market.KOSPI: 5000.0,  # KRW
        Market.KOSDAQ: 5000.0,  # KRW
    }

    @classmethod
    def _cheap_price(cls, market: Optional[Market]) -> float:
        """'Cheap' price ceiling (legacy <250-300 IDR) scaled per market.

        Original markets (IDX/HKEX/KOSPI/KOSDAQ) keep their hand-tuned ceilings;
        new markets derive theirs from the shared FX table so the ceiling lands
        in sane local-currency magnitude (e.g. US ~= 300/16000 USD).
        """
        if market is None:
            return cls._CHEAP_PRICE_BASE_IDR
        override = cls._CHEAP_PRICE_OVERRIDE.get(market)
        if override is not None:
            return override
        return cls._CHEAP_PRICE_BASE_IDR / _idr_per_unit(market)

    def _signal_and_score(
        self,
        ind: dict,
        cats: List[ScreenerCategory],
        ctx: Optional[MarketContext] = None,
        market: Optional[Market] = None,
        win_probability: Optional[float] = None,
    ):
        """Institutional-grade multi-factor score + BUY/HOLD/SELL signal.

        Delegates to :mod:`app.scoring`:
          * weighted 7-factor composite (trend/momentum/volume/relative
            strength/volatility/market regime/liquidity);
          * hard quality penalties (gap / pump-dump / untrended spike / extreme
            ATR / sub-$1-equivalent);
          * Phase-4 calibration curve (reserves 90+ for genuine confluence);
          * optional ML blend ``0.7*technical + 0.3*(100*win_prob)``.

        ``ctx`` (relative strength + regime) and ``win_probability`` are
        optional; without them the relevant factors fall back to neutral so the
        score is always well-defined. Applied identically to every market.
        """
        technical = scoring.technical_score(ind, ctx, market)
        final = scoring.blend_with_ml(technical, win_probability)
        signal = scoring.signal_for_score(final)
        # Phase F: liquidity cap is the LAST step — technical/ML can never push
        # an illiquid name above its value-traded tier, and an illiquid name
        # can never be BUY. Stash the reason so analyze() can surface it.
        capped, signal, illiquid, reason = scoring.apply_liquidity_cap(
            final, signal, ind, market
        )
        self._last_liquidity_illiquid = illiquid
        self._last_liquidity_reason = reason
        return signal, round(capped, 1)

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
            # Real RandomForest profit probability; placeholder if untrainable.
            ml_prob = self._profit_model.probability(
                df, market.value, symbol.upper()
            )
            ctx = self._market_context(df, market)
            # Blend ML only when explicitly enabled AND the probability is
            # non-degenerate (a thin per-symbol RandomForest that returns
            # exactly 0.0/1.0 is over-confident on too little data). Otherwise
            # the deterministic multi-factor technical score is the headline.
            blend_prob = None
            if _ML_BLEND and ml_prob is not None and 0.0 < ml_prob < 1.0:
                blend_prob = ml_prob
            signal, score = self._signal_and_score(
                ind, cats, ctx=ctx, market=market, win_probability=blend_prob
            )
            tags = ", ".join(c.value for c in cats) or "none"
            ts_pct, ts_price = self._trailing_stop(ind, cats)
            # Last completed bar's date (for the CLOSED "Last Market Close").
            last_date = None
            try:
                last_date = df.index[-1].to_pydatetime()
            except Exception:  # noqa: BLE001 - date is best-effort
                last_date = None
            # profit_probability field: real ML when available, else a
            # score-derived placeholder (unchanged contract).
            profit_prob = ml_prob
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
                illiquid=self._last_liquidity_illiquid,
                liquidity_note=self._last_liquidity_reason,
            )
        except Exception as exc:  # noqa: BLE001 - intentional safe fallback
            logger.warning("analyze fell back to mock for %s: %s", ticker, exc)
            return mock_data.mock_analyze(symbol, market)

    def _close_from_df(self, df) -> Optional[float]:
        try:
            close = df["Close"].dropna()
        except Exception:  # noqa: BLE001
            return None
        if close.empty:
            return None
        return float(close.iloc[-1])

    def latest_price_cached(
        self, symbol: str, market: Market
    ) -> Optional[float]:
        """Latest cached close WITHOUT a network fetch (best-effort, instant).

        Reads only what is already on disk (regardless of TTL). Returns None
        when nothing is cached. Used by latency-sensitive callers (simulated
        order pricing) that must never block on a slow/blocked data provider.
        """
        cache = getattr(self._fetch, "cache", None)
        if cache is None:
            return None
        ticker = yf_symbol(symbol, market)
        try:
            df = cache.read_cached_only(ticker, "1mo", "1d")
        except Exception:  # noqa: BLE001 - best-effort
            return None
        if df is None:
            return None
        return self._close_from_df(df)

    def latest_price(self, symbol: str, market: Market) -> Optional[float]:
        """Latest close price for a symbol via the unified cached fetch path.

        Read-only helper used by the simulated portfolio for mark-to-market and
        market-order execution. Reuses the same fetcher/cache as analyze(); does
        NOT touch scoring/indicators. Returns None if no real price is
        available (caller decides how to handle).
        """
        ticker = yf_symbol(symbol, market)
        try:
            df = self._fetch(ticker, "1mo", "1d")
            return self._close_from_df(df)
        except Exception as exc:  # noqa: BLE001 - price is best-effort
            logger.warning("latest_price failed for %s: %s", ticker, exc)
            return None

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

        # Phase C: aggregate fallback logging. Instead of one ERROR/WARNING per
        # failed ticker (thousands of lines), emit a single market-level summary
        # when any symbol fell back to deterministic mock data.
        total = len(matches)
        fallback = sum(
            1 for m in matches if getattr(m, "data_source", "live") == "mock"
        )
        if fallback:
            logger.warning(
                "%s screen fallback used for %d/%d symbols "
                "(no live data; held out of BUY/elite ideas).",
                market.value, fallback, total,
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
            ctx = self._market_context(df, market)
            signal, score = self._signal_and_score(
                ind, cats, ctx=ctx, market=market
            )
            change_pct = _daily_change_pct(df)
            illiquid = self._last_liquidity_illiquid
            # Phase 9A: additive Explore overlay (category bonus + conviction).
            # Illiquid names get NO bonus/conviction so they can't be lifted
            # into the top ranks (Rule 8 #6); their Final Score == Base Score.
            # Bug fix: the additive overlay must also respect the LIQUIDITY CAP
            # that constrained the Base Score. Without a ceiling, a thin name
            # (20-day avg turnover below its value-traded tier, e.g. an IDX
            # stock under Rp5B capped at 75) could be lifted back to a BUY-grade
            # Final Score by the +bonus/+conviction overlay, defeating the cap.
            # Re-derive the same liquidity tier and pass it as a hard ceiling.
            cap_ceiling, _, _ = scoring.liquidity_cap_for(
                scoring._value_traded(ind), market
            )
            overlay = explore.compute_overlay(
                score,
                cats,
                ind,
                allow_bonus=not illiquid,
                score_ceiling=cap_ceiling,
            )
            # Phase 11B: surface the liquidity participation score + the raw
            # turnover/volume figures so Explore can show the liquidity
            # contribution. Pure read-out of already-computed indicators.
            part = scoring.participation_score(ind, market)

            def _num(v):
                try:
                    return round(float(v), 2) if v is not None else None
                except (TypeError, ValueError):
                    return None

            return ScreenerMatch(
                symbol=sym.upper(),
                name=names.get(sym.upper(), sym.upper()),
                score=score,
                signal=signal,
                price=round(ind["close"], 2),
                change_percent=round(change_pct, 2),
                categories=cats,
                value_traded=round(ind.get("value_traded") or 0.0, 2),
                illiquid=illiquid,
                liquidity_note=(
                    "Illiquid — not investable" if illiquid else None
                ),
                base_score=overlay["base_score"],
                category_bonus=overlay["category_bonus"],
                conviction_score=overlay["conviction_score"],
                final_score=overlay["final_score"],
                explore_tags=overlay["explore_tags"],
                liquidity_score=round(part, 1),
                participation_score=round(part, 1),
                value_traded_today=_num(ind.get("value_traded")),
                avg_value_traded_20d=_num(
                    ind.get("avg_value_traded_20d")
                    or ind.get("avg_value_traded")
                ),
                volume_today=_num(ind.get("volume")),
                avg_volume_20d=_num(
                    ind.get("avg_volume_20d") or ind.get("vol_mean_20")
                ),
                volume_ratio_20d=_num(
                    ind.get("volume_ratio_20d") or ind.get("volume_ratio")
                ),
                value_traded_ratio_20d=_num(
                    ind.get("value_traded_ratio_20d")
                ),
            )
        except Exception as exc:  # noqa: BLE001
            # Keep the universe fully populated; response stays 200 "live".
            # Per-symbol detail is DEBUG only; the caller (screen()) emits a
            # single aggregated WARNING summary per run to avoid log spam.
            logger.debug("screen mock-fallback for %s: %s", ticker, exc)
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
        ``min_value_traded`` (liquidity floor). Sort (Phase 9A): Final Explore
        Score desc, then value_traded desc (liquidity tiebreaker), then
        change_percent desc. ``min_score`` still filters on the Base Score so
        existing callers keep their semantics.
        """
        limit = max(1, min(int(limit), MAX_LIMIT))
        wanted = set(categories or [])

        def _durable_value_traded(m: ScreenerMatch) -> float:
            """Liquidity-floor anchor: a name's durable daily turnover.

            Uses the 20-day average when available so a genuinely liquid name
            isn't dropped from Explore on a single quiet session (the IDX
            liquidity bug); a one-day pump can't sneak in either, because the
            average barely moves. Falls back to today's turnover otherwise.
            """
            avg = getattr(m, "avg_value_traded_20d", None)
            if avg is not None and avg > 0:
                return max(avg, m.value_traded)
            return m.value_traded

        # Hold mock-fallback rows out of the visible results whenever real live
        # data exists for the run. A symbol that failed its live fetch carries
        # deterministic *seeded* placeholder price/score/turnover (e.g. GOTO at
        # a fabricated 776 instead of its real ~80). Letting those rows rank
        # makes Explore (a) show wrong index/price values and (b) flip between
        # runs as the live/mock mix shifts with yfinance availability. We only
        # keep mock rows when the ENTIRE response is mock (no universe / fully
        # offline demo mode), so that path still returns something.
        live_present = any(
            getattr(m, "data_source", "live") != "mock" for m in result.matches
        )

        matches = [
            m
            for m in result.matches
            if (not live_present or getattr(m, "data_source", "live") != "mock")
            and m.score >= min_score
            and _durable_value_traded(m) >= min_value_traded
            and (not wanted or wanted.intersection(m.categories))
        ]

        def _rank_score(m: ScreenerMatch) -> float:
            # Sort by Final Explore Score when present; fall back to the Base
            # Score for rows that predate the overlay (e.g. older snapshots).
            fs = getattr(m, "final_score", None)
            return fs if fs is not None else m.score

        matches.sort(
            key=lambda m: (_rank_score(m), m.value_traded, m.change_percent),
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
