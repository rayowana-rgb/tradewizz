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
    df = yf.download(ticker, **kwargs)
    if df is None or df.empty:
        raise ValueError(f"No data for {ticker}")
    # yfinance may return a column MultiIndex for a single ticker; flatten it.
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    if "Close" not in df.columns:
        raise ValueError(f"Missing Close column for {ticker}: {df.columns}")
    return df


@dataclass(frozen=True)
class MarketIndexSpec:
    """Static mapping of a market to its Yahoo index symbol + display info."""

    market: Market
    symbol: str
    name: str
    currency: str


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
    MarketIndexSpec(Market.VIETNAM, "^VNINDEX", "VN-Index", "VND"),
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
        try:
            df = self._fetch(spec.symbol, "5d", "1d")
            price, change, change_pct = self._extract(df)
        except Exception:  # noqa: BLE001 - any failure -> safe unavailable
            return self._unavailable(spec, status)
        if price is None:
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
