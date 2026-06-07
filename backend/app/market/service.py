"""Market index quotes for the Dashboard.

For each supported market we resolve the correct Yahoo Finance **index** symbol
(not a stock-ticker proxy), fetch the latest close + previous close to compute
the change, derive the market OPEN/CLOSED status from the existing session
schedule, and serve it behind a short in-memory cache (default 5 minutes).

Design notes:
- The price fetch is injectable (`Fetcher`) so tests run with no network. The
  default reuses the engine's `_yf_fetch` (same Yahoo pattern / browser
  impersonation as the rest of the app). No new data provider is introduced.
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
    _is_market_open,
    _market_now,
    _yf_fetch,
)
from ..models import Market


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
        # Default fetcher = the engine's Yahoo fetch (same pattern as analysis).
        self._fetch: Fetcher = fetcher or _yf_fetch
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
        """Latest close + change vs the prior close from an OHLCV frame."""
        if df is None or df.empty or "Close" not in df.columns:
            return None, None, None
        closes = df["Close"].dropna()
        if closes.empty:
            return None, None, None
        last = float(closes.iloc[-1])
        if len(closes) >= 2:
            prev = float(closes.iloc[-2])
            change = last - prev
            change_pct = (change / prev * 100.0) if prev != 0 else None
        else:
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
