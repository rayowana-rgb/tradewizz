"""Market index quotes for the Dashboard.

For each supported market we resolve the correct Yahoo Finance **index** symbol
(not a stock-ticker proxy), fetch the latest close + previous close to compute
the change, derive the market OPEN/CLOSED status from the existing session
schedule, and serve it behind a short in-memory cache (default 5 minutes).

Design notes:
- The price fetch is injectable (`Fetcher`) so tests run with no network. The
  default is an *index-tolerant* Yahoo fetch (`_index_fetch`) using the same
  Yahoo pattern / browser impersonation, but requiring only a `Close` column.
  The engine's strict `_yf_fetch` requires a full OHLCV frame (it is shared
  with analysis/screener which need volume); index symbols (^JKSE etc.) often
  come back without Volume, so reusing the strict fetcher wrongly marked them
  unavailable. No new data provider is introduced and `_yf_fetch` is untouched.
- On any fetch failure we return a *safe unavailable* quote (price=None,
  status preserved) rather than fabricating numbers — the Dashboard then shows
  a clear "Index data unavailable" warning instead of wrong values.
- This cache is separate from the screener snapshot cache.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional

import pandas as pd

from ..engine import (
    Fetcher,
    _YF_TIMEOUT,
    _impersonating_session,
    _is_market_open,
    _market_now,
    _with_yf_retry,
)
from ..models import Market


def _index_fetch(
    ticker: str, period: str = "5d", interval: str = "1d"
) -> pd.DataFrame:
    """Yahoo fetch tuned for *indices* (only ``Close`` is required).

    The engine's ``_yf_fetch`` is intentionally strict: it requires a full
    OHLCV frame (Open/High/Low/Close/Volume) because stock analysis + the
    screener need volume / value-traded. Index symbols (``^JKSE`` etc.) often
    come back from Yahoo with Volume missing or all-NaN/zero, which would make
    that strict gate raise and wrongly mark the index unavailable.

    This fetcher uses the same Yahoo pattern / browser impersonation but only
    requires a ``Close`` column, so an index with a valid Close is usable even
    when Volume / OHLC are absent. It does NOT replace ``_yf_fetch`` and is
    used only by the index service.
    """
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

    def _download() -> pd.DataFrame:
        df = yf.download(ticker, **kwargs)
        if df is None or df.empty:
            raise ValueError(f"No data for {ticker}")
        return df

    # Same anti-429 retry/backoff as the screener fetch so a throttled index
    # request is recovered instead of falling back to a stale daily candle.
    df = _with_yf_retry(_download, label=ticker)
    # yfinance may return a column MultiIndex for a single ticker; flatten it
    # robustly (the level that contains 'Close' is the field level, regardless
    # of (field,ticker) vs (ticker,field) order) and drop duplicate columns.
    if isinstance(df.columns, pd.MultiIndex):
        field_level = 0
        for lvl in range(df.columns.nlevels):
            if "Close" in set(df.columns.get_level_values(lvl)):
                field_level = lvl
                break
        df.columns = df.columns.get_level_values(field_level)
    if getattr(df.columns, "duplicated", None) is not None and df.columns.duplicated().any():
        df = df.loc[:, ~df.columns.duplicated()]
    if "Close" not in df.columns:
        raise ValueError(f"Missing Close column for {ticker}: {df.columns}")
    return df


def _fetch_vix_level() -> Optional[float]:
    """Latest CBOE VIX close (``^VIX``), or None on any failure.

    The VIX is the market's forward-looking implied-volatility "fear gauge"
    for US equities. Reuses the index-tolerant fetcher (Close-only). Best
    effort: never raises, so a VIX outage just drops the signal.
    """
    try:
        df = _index_fetch("^VIX", "5d", "1d")
        closes = pd.to_numeric(df["Close"], errors="coerce").dropna()
        if closes.empty:
            return None
        value = float(closes.iloc[-1])
        # Sanity bound: VIX realistically trades ~9..90.
        if value <= 0 or value > 200:
            return None
        return value
    except Exception:  # noqa: BLE001 - VIX is optional
        return None


@dataclass(frozen=True)
class MarketIndexSpec:
    """Static mapping of a market to its Yahoo index symbol + display info."""

    market: Market
    symbol: str
    name: str
    currency: str
    # Some markets have no working public Yahoo index symbol (e.g. Vietnam's
    # VN-Index: ^VNINDEX / VNINDEX.VN all 404). For those we skip the fetch
    # entirely and report a clean ``available=false`` / ``UNKNOWN`` state
    # instead of hammering Yahoo with guaranteed-404 requests every cache
    # window (which produced thousands of error lines).
    fetchable: bool = True
    unavailable_reason: Optional[str] = None


# Correct Yahoo Finance *index* symbols (verified format). Never use a stock
# ticker as an index proxy.
INDEX_SPECS: List[MarketIndexSpec] = [
    MarketIndexSpec(Market.IDX, "^JKSE", "IHSG", "IDR"),
    MarketIndexSpec(Market.HKEX, "^HSI", "Hang Seng", "HKD"),
    MarketIndexSpec(Market.KOSPI, "^KS11", "KOSPI Composite", "KRW"),
    MarketIndexSpec(Market.KOSDAQ, "^KQ11", "KOSDAQ Composite", "KRW"),
    # --- Global market expansion ---
    MarketIndexSpec(Market.US, "^GSPC", "S&P 500", "USD"),
    MarketIndexSpec(Market.JAPAN, "^N225", "Nikkei 225", "JPY"),
    MarketIndexSpec(Market.INDIA, "^NSEI", "Nifty 50", "INR"),
    MarketIndexSpec(
        Market.VIETNAM, "^VNINDEX", "VN-Index", "VND",
        fetchable=False,
        unavailable_reason="VN-Index has no public Yahoo Finance symbol.",
    ),
    MarketIndexSpec(Market.SINGAPORE, "^STI", "Straits Times Index", "SGD"),
]

INDEX_BY_MARKET: Dict[Market, MarketIndexSpec] = {
    spec.market: spec for spec in INDEX_SPECS
}


@dataclass(frozen=True)
class IndexQuote:
    """A single index quote for the API response."""

    symbol: str
    market: Market
    name: str
    currency: str
    status: str  # "OPEN" | "CLOSED"
    price: Optional[float]
    change: Optional[float]
    change_percent: Optional[float]
    updated_at: str
    available: bool

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "market": self.market.value,
            "name": self.name,
            "price": self.price,
            "change": self.change,
            "change_percent": self.change_percent,
            "currency": self.currency,
            "status": self.status,
            "updated_at": self.updated_at,
            "available": self.available,
        }


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


# A real equity index never moves this much in a single session. Used to
# reject Yahoo rate-limited / partial candles that parse into absurd levels.
_MAX_INDEX_DAILY_MOVE_PCT = 25.0

# A real index tick stays within the same order of magnitude as its recent
# level. Yahoo sometimes returns a corrupt candle ~100x off (e.g. 67 vs 6000).
# Accept a tick only if it is within [1/3x, 3x] of the reference level.
_LEVEL_RATIO_TOLERANCE = 3.0


def _level_is_consistent(
    value: Optional[float], reference: Optional[float]
) -> bool:
    """True if ``value`` is the same order of magnitude as ``reference``.

    Used to reject corrupt Yahoo candles whose level is wildly off (e.g. an
    intraday tick of 67 when the index trades near 6000). A missing reference
    means we cannot judge -> treat as consistent (don't over-reject).
    """
    if value is None or value <= 0:
        return False
    if reference is None or reference <= 0:
        return True
    ratio = value / reference
    return (1.0 / _LEVEL_RATIO_TOLERANCE) <= ratio <= _LEVEL_RATIO_TOLERANCE


class MarketIndicesService:
    """Fetches + caches index quotes for all markets."""

    def __init__(
        self,
        fetcher: Optional[Fetcher] = None,
        ttl_seconds: int = 300,  # 5 minutes
        clock: Callable[[], float] = time.time,
        now_provider: Optional[Callable[[Market], datetime]] = None,
    ):
        # Default fetcher = an index-tolerant Yahoo fetch that requires only
        # Close (indices often lack Volume), distinct from the strict OHLCV
        # _yf_fetch used by analysis/screener.
        self._fetch: Fetcher = fetcher or _index_fetch
        self._ttl = ttl_seconds
        self._clock = clock
        self._now = now_provider or _market_now
        self._lock = threading.Lock()
        # symbol -> (fetched_at, IndexQuote)
        self._cache: Dict[str, tuple[float, IndexQuote]] = {}

    # -- public ------------------------------------------------------------

    def get_indices(self) -> List[IndexQuote]:
        """Return one quote per supported market (cached, ~5 min)."""
        return [self._get_one(spec) for spec in INDEX_SPECS]

    # -- internals ---------------------------------------------------------

    def _status(self, spec: MarketIndexSpec) -> str:
        return "OPEN" if _is_market_open(spec.market, self._now(spec.market)) \
            else "CLOSED"

    def _get_one(self, spec: MarketIndexSpec) -> IndexQuote:
        with self._lock:
            entry = self._cache.get(spec.symbol)
            if entry is not None:
                fetched_at, quote = entry
                if 0 <= (self._clock() - fetched_at) < self._ttl:
                    # Status is cheap + time-sensitive: recompute on read so a
                    # market opening/closing within the cache window is correct.
                    return self._with_status(quote, self._status(spec))
        quote = self._fetch_quote(spec)
        # If a fresh fetch came back unavailable (e.g. rejected absurd candle or
        # a transient Yahoo failure) but we still hold a previously-good quote,
        # keep serving the last-good value instead of regressing to a blank/null
        # index. We deliberately do NOT overwrite the good cache with the bad
        # one, so the next read retries the fetch.
        if not quote.available:
            with self._lock:
                entry = self._cache.get(spec.symbol)
            if entry is not None and entry[1].available:
                return self._with_status(entry[1], self._status(spec))
            return quote
        with self._lock:
            self._cache[spec.symbol] = (self._clock(), quote)
        return quote

    @staticmethod
    def _with_status(quote: IndexQuote, status: str) -> IndexQuote:
        if quote.status == status:
            return quote
        return IndexQuote(
            symbol=quote.symbol,
            market=quote.market,
            name=quote.name,
            currency=quote.currency,
            status=status,
            price=quote.price,
            change=quote.change,
            change_percent=quote.change_percent,
            updated_at=quote.updated_at,
            available=quote.available,
        )

    def _fetch_quote(self, spec: MarketIndexSpec) -> IndexQuote:
        status = self._status(spec)
        # Markets with no working Yahoo index symbol: skip the fetch and report
        # a clean unavailable state (no 404 spam, isolated to this index).
        if not spec.fetchable:
            return self._unavailable(spec, status)
        try:
            df = self._fetch(spec.symbol, "5d", "1d")
            price, change, change_pct = self._extract(df)
            # Daily-level sanity: reject a corrupt daily Close that is wildly off
            # the recent level (e.g. Yahoo hands back 67 when IHSG trades ~6000,
            # which slips past the change% guard when BOTH rows are mis-scaled).
            daily_ref = self._reference_level(df)
            if price is not None and not _level_is_consistent(price, daily_ref):
                return self._unavailable(spec, status)
            # Yahoo's DAILY index candle lags: after the session closes, today's
            # 1d candle often is not published for hours, so _extract returns
            # YESTERDAY's close (the "Home shows kemarin's close" bug). Pull an
            # intraday last tick; if it is from a more recent trading day than
            # the latest daily candle, it is today's real level -> use it and
            # recompute change against the last DAILY close.
            intraday = self._intraday_last(spec.symbol)
            last_daily_date, last_daily_close = self._last_daily(df)
            if intraday is not None:
                intra_date, intra_price = intraday
                if (
                    last_daily_date is not None
                    and intra_date > last_daily_date
                    and intra_price is not None
                    # Level sanity: a real index tick stays within the same
                    # order of magnitude as the last daily close. Yahoo can hand
                    # back a corrupt/parsed-wrong candle (e.g. ~67 when IHSG is
                    # ~6000); reject it so we keep the trusted daily level.
                    and _level_is_consistent(intra_price, last_daily_close)
                ):
                    price = intra_price
                    change = intra_price - last_daily_close
                    change_pct = (
                        (change / last_daily_close * 100.0)
                        if last_daily_close
                        else None
                    )
        except Exception:  # noqa: BLE001 - any failure -> safe unavailable
            return self._unavailable(spec, status)
        if price is None:
            return self._unavailable(spec, status)
        # Sanity guard: a real equity index never gaps +/-25% in one session.
        # Yahoo occasionally returns a rate-limited / partial candle that parses
        # into an absurd level (e.g. IHSG "754.83 / -87%"). Reject it as a bad
        # fetch rather than caching fabricated numbers; the caller keeps the
        # last-good quote (or reports unavailable on a cold start).
        if (
            change_pct is not None
            and abs(change_pct) > _MAX_INDEX_DAILY_MOVE_PCT
        ) or price <= 0:
            return self._unavailable(spec, status)
        return IndexQuote(
            symbol=spec.symbol,
            market=spec.market,
            name=spec.name,
            currency=spec.currency,
            status=status,
            price=round(price, 2),
            change=round(change, 2) if change is not None else None,
            change_percent=round(change_pct, 2)
            if change_pct is not None
            else None,
            updated_at=_now_iso(),
            available=True,
        )

    @staticmethod
    def _extract(
        df: pd.DataFrame,
    ) -> tuple[Optional[float], Optional[float], Optional[float]]:
        """Latest valid close + change vs the prior valid close.

        Index-tolerant: only ``Close`` is needed (Volume / OHLC may be absent).
        NaN closes are dropped, so a NaN latest row falls back to the last
        valid Close. With a single valid Close the price is returned while
        change / change_percent stay None (still ``available``).
        """
        if df is None or df.empty or "Close" not in df.columns:
            return None, None, None
        close = df["Close"]
        # Guard against a duplicate 'Close' producing a DataFrame slice.
        if isinstance(close, pd.DataFrame):
            close = close.iloc[:, 0]
        closes = pd.to_numeric(close, errors="coerce").dropna()
        if closes.empty:
            return None, None, None
        last = float(closes.iloc[-1])
        if len(closes) >= 2:
            prev = float(closes.iloc[-2])
            change = last - prev
            change_pct = (change / prev * 100.0) if prev != 0 else None
        else:
            # Only one valid Close: price available, change unknown.
            change = None
            change_pct = None
        return last, change, change_pct

    @staticmethod
    def _last_daily(df: pd.DataFrame) -> tuple[Optional[object], Optional[float]]:
        """(date, close) of the latest valid DAILY candle, or (None, None)."""
        if df is None or df.empty or "Close" not in df.columns:
            return None, None
        close = df["Close"]
        if isinstance(close, pd.DataFrame):
            close = close.iloc[:, 0]
        closes = pd.to_numeric(close, errors="coerce").dropna()
        if closes.empty:
            return None, None
        ts = closes.index[-1]
        try:
            day = ts.date()
        except AttributeError:
            day = pd.Timestamp(ts).date()
        return day, float(closes.iloc[-1])

    @staticmethod
    def _reference_level(df: pd.DataFrame) -> Optional[float]:
        """Robust recent level (median of valid daily closes), or None.

        Used as a stable yardstick to detect a corrupt latest Close that is an
        order of magnitude off. The median ignores a single mis-scaled row, so
        a 67-vs-6000 glitch is caught even when it is the most recent candle.
        """
        if df is None or df.empty or "Close" not in df.columns:
            return None
        close = df["Close"]
        if isinstance(close, pd.DataFrame):
            close = close.iloc[:, 0]
        closes = pd.to_numeric(close, errors="coerce").dropna()
        if closes.empty:
            return None
        return float(closes.median())

    # Intraday fetch attempts, in priority order. ``1d/1m`` is the freshest but
    # Yahoo returns it EMPTY for several index symbols (notably ^JKSE), so we
    # fall back to ``5d/5m`` which DOES carry today's/yesterday's index ticks
    # for those symbols. Without this fallback IDX stays frozen on an old daily
    # close (the "IHSG shows last week" bug).
    _INTRADAY_ATTEMPTS = (("1d", "1m"), ("5d", "5m"))

    def _intraday_last(
        self, symbol: str
    ) -> Optional[tuple[object, Optional[float]]]:
        """Latest intraday close + its trading date, or None.

        Used only to detect/serve TODAY's index level when the daily candle
        still lags. Tries progressively coarser intraday windows so a symbol
        whose 1m feed is empty (e.g. ^JKSE) still resolves via 5m. Any failure
        is swallowed so the daily path keeps working.
        """
        for period, interval in self._INTRADAY_ATTEMPTS:
            try:
                df = self._fetch(symbol, period, interval)
            except Exception:  # noqa: BLE001 - intraday is best-effort
                continue
            if df is None or df.empty or "Close" not in df.columns:
                continue
            close = df["Close"]
            if isinstance(close, pd.DataFrame):
                close = close.iloc[:, 0]
            closes = pd.to_numeric(close, errors="coerce").dropna()
            if closes.empty:
                continue
            ts = closes.index[-1]
            try:
                day = ts.date()
            except AttributeError:
                day = pd.Timestamp(ts).date()
            return day, float(closes.iloc[-1])
        return None

    @staticmethod
    def _unavailable(spec: MarketIndexSpec, status: str) -> IndexQuote:
        return IndexQuote(
            symbol=spec.symbol,
            market=spec.market,
            name=spec.name,
            currency=spec.currency,
            status=status,
            price=None,
            change=None,
            change_percent=None,
            updated_at=_now_iso(),
            available=False,
        )


class MarketConditionService:
    """Phase E: rule-based Fear/Greed condition for a market's index.

    Fetches ~1y of the market's benchmark index (index-tolerant: only Close is
    required) and classifies it via :func:`condition.classify_condition`.
    Cached ~5 minutes per market. Any failure -> a neutral ``UNKNOWN`` result
    (never crashes, never fabricates).
    """

    def __init__(
        self,
        fetcher: Optional[Fetcher] = None,
        ttl_seconds: int = 300,
        clock: Callable[[], float] = time.time,
        breadth_provider: Optional[
            Callable[[Market], tuple]
        ] = None,
        vix_fetcher: Optional[Callable[[], Optional[float]]] = None,
    ):
        self._fetch: Fetcher = fetcher or _index_fetch
        self._ttl = ttl_seconds
        self._clock = clock
        self._lock = threading.Lock()
        self._cache: Dict[Market, tuple] = {}
        # Optional sentiment inputs. Both are best-effort: any error is swallowed
        # and the corresponding signal is simply skipped (price-only fallback).
        self._breadth_provider = breadth_provider
        self._vix_fetcher = vix_fetcher or _fetch_vix_level

    def _breadth(self, market: Market) -> tuple:
        """(advances, declines) for the market, or (None, None) on any failure."""
        if self._breadth_provider is None:
            return (None, None)
        try:
            adv, dec = self._breadth_provider(market)
            return (adv, dec)
        except Exception:  # noqa: BLE001 - breadth is optional
            return (None, None)

    def _vix(self, market: Market) -> Optional[float]:
        """Current VIX level (US only), or None when unavailable/non-US."""
        if market != Market.US or self._vix_fetcher is None:
            return None
        try:
            return self._vix_fetcher()
        except Exception:  # noqa: BLE001 - VIX is optional
            return None

    def get(self, market: Market):
        from .condition import (
            MarketCondition,
            classify_condition,  # noqa: F401 - kept for back-compat callers
            classify_multi_horizon,
        )

        # While the market is CLOSED the underlying daily candles do not change,
        # so the Fear/Greed reading must stay stable for the whole closed period
        # instead of flickering every time the short TTL lapses and we re-pull a
        # (sometimes still-forming / revised) bar from Yahoo. We therefore key
        # the cache on the current trading date and only honour the short TTL
        # while a session is actually open.
        try:
            from ..market_session import current_trading_date, is_session_open
            now = datetime.now(timezone.utc)
            trading_date = current_trading_date(market, now)
            session_open = is_session_open(market, now)
        except Exception:  # noqa: BLE001 - fall back to plain TTL caching
            trading_date = None
            session_open = True

        with self._lock:
            entry = self._cache.get(market)
            if entry is not None:
                cached_at, cached_result, cached_td = entry
                if session_open:
                    # Live session: keep it fresh on the short TTL.
                    if self._clock() - cached_at < self._ttl:
                        return cached_result
                else:
                    # Market closed: serve the cached reading for the entire
                    # closed period (same trading date) so it doesn't change.
                    if trading_date is not None and cached_td == trading_date:
                        return cached_result
                    # Trading-date unknown -> fall back to the short TTL.
                    if trading_date is None and \
                            self._clock() - cached_at < self._ttl:
                        return cached_result
        spec = INDEX_BY_MARKET.get(market)
        if spec is None:
            return MarketCondition(
                "UNKNOWN", 50, "No index available for this market."
            )
        if not spec.fetchable:
            # No working Yahoo symbol (e.g. Vietnam): clean unavailable state,
            # no fetch attempt, isolated to this market.
            result = MarketCondition.unavailable(
                spec.unavailable_reason or "Index data unavailable"
            )
            with self._lock:
                self._cache[market] = (self._clock(), result, trading_date)
            return result
        try:
            df = self._fetch(spec.symbol, "1y", "1d")
            closes, highs, lows = _ohlc_series(df)
            advances, declines = self._breadth(market)
            vix = self._vix(market)
            result = classify_multi_horizon(
                closes, highs, lows,
                advances=advances, declines=declines, vix=vix,
            )
        except Exception:  # noqa: BLE001 - best-effort, never crash
            result = MarketCondition(
                "UNKNOWN", 50, "Market condition data unavailable."
            )
        with self._lock:
            self._cache[market] = (self._clock(), result, trading_date)
        return result


def _ohlc_series(df: pd.DataFrame):
    """Extract (closes, highs, lows) numeric lists oldest->newest, NaN-safe."""
    if df is None or df.empty or "Close" not in df.columns:
        return None, None, None

    def _col(name):
        if name not in df.columns:
            return None
        s = df[name]
        if isinstance(s, pd.DataFrame):
            s = s.iloc[:, 0]
        s = pd.to_numeric(s, errors="coerce").dropna()
        return [float(x) for x in s.tolist()]

    closes = _col("Close")
    highs = _col("High")
    lows = _col("Low")
    return closes, highs, lows
