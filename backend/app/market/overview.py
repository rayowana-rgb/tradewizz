"""Dashboard Market Overview aggregation.

Builds a per-market overview from the *existing* screener universe snapshot
(real price/change/value-traded per symbol), so no new data source and no mock
values are introduced here:

  - market breadth: advances / declines / unchanged
  - top gainer / top loser (by daily % change)
  - total market value traded (sum of per-symbol turnover)
  - foreign flow (IDX only; reported unavailable when no real source exists)

The heavy universe screen is delegated to an injected callable (wired to the
market-close screener cache in main.py) so this layer stays fast and reuses
cached data; results are additionally held in a short in-memory cache
(default 5 minutes). On any failure the overview reports `available=false`
with null aggregates rather than fabricating numbers.
"""

from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional

from ..models import Market, ScreenerMatch, ScreenerResult

# Cache-only probe (no network fetch) reused from the screener cache: returns
# the newest OHLCV "data freshness" timestamp for a market. Used to detect that
# the underlying data refreshed after this overview was built, so a stale
# overview is not served from the short in-memory cache.
from ..screener_cache.service import (  # noqa: E402
    LatestDataTimestamp,
    latest_market_candle_ts,
)


# How many rows each Top-Movers tab (Gainers / Losers / Most Active) returns.
_MOVERS_LIMIT = 8


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_iso(value: object) -> Optional[datetime]:
    """Parse an ISO-8601 string to a tz-aware UTC datetime, or None."""
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value))
    except (TypeError, ValueError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


@dataclass(frozen=True)
class MoverRef:
    symbol: str
    name: str
    price: float
    change_percent: float
    # Daily turnover (close * volume) in the market currency. Additive/optional
    # so the single top_gainer/top_loser refs stay backward-compatible; the
    # Most-Active movers list sorts by this.
    value_traded: float = 0.0

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "name": self.name,
            "price": self.price,
            "change_percent": self.change_percent,
            "value_traded": self.value_traded,
        }


@dataclass(frozen=True)
class ForeignFlow:
    """Net foreign flow (IDX). `available=false` when no real source exists."""

    available: bool
    net_value: Optional[float] = None
    currency: str = "IDR"

    def to_dict(self) -> dict:
        return {
            "available": self.available,
            "net_value": self.net_value,
            "currency": self.currency,
        }


@dataclass(frozen=True)
class MarketOverview:
    market: Market
    available: bool
    status: Optional[str]
    advances: Optional[int]
    declines: Optional[int]
    unchanged: Optional[int]
    total_symbols: Optional[int]
    total_value_traded: Optional[float]
    currency: str
    top_gainer: Optional[MoverRef]
    top_loser: Optional[MoverRef]
    foreign_flow: Optional[ForeignFlow]
    updated_at: str
    # --- Top Movers grid (additive, optional) ----------------------------
    # Ranked top-N lists derived from the SAME universe screen that backs
    # breadth/top_gainer/top_loser (no new data source). Default empty so
    # older snapshots/clients render unchanged.
    top_gainers: tuple["MoverRef", ...] = ()
    top_losers: tuple["MoverRef", ...] = ()
    most_active: tuple["MoverRef", ...] = ()

    def to_dict(self) -> dict:
        return {
            "market": self.market.value,
            "available": self.available,
            "status": self.status,
            "breadth": {
                "advances": self.advances,
                "declines": self.declines,
                "unchanged": self.unchanged,
                "total": self.total_symbols,
            },
            "total_value_traded": self.total_value_traded,
            "currency": self.currency,
            "top_gainer": self.top_gainer.to_dict() if self.top_gainer else None,
            "top_loser": self.top_loser.to_dict() if self.top_loser else None,
            "top_gainers": [m.to_dict() for m in self.top_gainers],
            "top_losers": [m.to_dict() for m in self.top_losers],
            "most_active": [m.to_dict() for m in self.most_active],
            "foreign_flow":
                self.foreign_flow.to_dict() if self.foreign_flow else None,
            "updated_at": self.updated_at,
        }


# Currency code per market (ISO-style, matches the indices endpoint).
_CURRENCY: Dict[Market, str] = {
    Market.IDX: "IDR",
    Market.HKEX: "HKD",
    Market.KOSPI: "KRW",
    Market.KOSDAQ: "KRW",
}


# A foreign-flow provider takes a Market and returns a ForeignFlow (or None).
ForeignFlowProvider = Callable[[Market], Optional[ForeignFlow]]


def _no_foreign_flow(market: Market) -> Optional[ForeignFlow]:
    """Default: only IDX exposes the row, and it is currently unavailable.

    We never fabricate a value. When a real EIKON/IDX foreign-flow source is
    wired in, replace this provider; until then IDX shows the row as
    `available=false` and other markets omit it (None).
    """
    if market == Market.IDX:
        return ForeignFlow(available=False, net_value=None, currency="IDR")
    return None


class MarketOverviewService:
    """Aggregates + caches the Dashboard market overview per market."""

    def __init__(
        self,
        run_screen: Callable[[Market], ScreenerResult],
        *,
        ttl_seconds: int = 300,  # 5 minutes
        clock: Callable[[], float] = time.time,
        foreign_flow: ForeignFlowProvider = _no_foreign_flow,
        latest_data_timestamp: Optional[LatestDataTimestamp] = (
            latest_market_candle_ts
        ),
    ):
        # run_screen(market) -> full-universe ScreenerResult (real data, cached
        # via the screener-cache wiring in main.py).
        self._run_screen = run_screen
        self._ttl = ttl_seconds
        self._clock = clock
        self._foreign_flow = foreign_flow
        # Cache-only probe: detects that the underlying OHLCV/analyze data
        # refreshed AFTER a cached overview was built, so the short in-memory
        # cache does not serve stale top-gainer/top-loser/breadth values while
        # the screener (and /analyze) already show fresh data. Injectable for
        # tests; defaults to the live cache-registry probe.
        self._latest_data_timestamp = latest_data_timestamp
        self._lock = threading.Lock()
        # built_at: when the overview was constructed (compared against the
        # data-freshness probe to invalidate on a same-day refresh).
        self._cache: Dict[Market, tuple[float, str, MarketOverview]] = {}

    # -- public ------------------------------------------------------------

    def get(self, market: Market) -> MarketOverview:
        with self._lock:
            entry = self._cache.get(market)
            if entry is not None:
                fetched_at, built_at, overview = entry
                fresh_ttl = 0 <= (self._clock() - fetched_at) < self._ttl
                if fresh_ttl and not self._data_is_newer(market, built_at):
                    return overview
        overview = self._build(market)
        with self._lock:
            self._cache[market] = (
                self._clock(), overview.updated_at, overview
            )
        return overview

    def _data_is_newer(self, market: Market, built_at: str) -> bool:
        """True when cached OHLCV data is newer than this overview's build time.

        Lightweight, cache-only check (no network fetch): compares the newest
        cached candle/refresh timestamp for the market against ``built_at``.
        Returns False (keep cached overview) whenever the comparison cannot be
        made -- no probe, nothing cached, or unparseable timestamps -- so
        behavior is unchanged when validation is indeterminate.
        """
        if self._latest_data_timestamp is None:
            return False
        try:
            latest = self._latest_data_timestamp(market.value)
        except Exception:  # noqa: BLE001 - never let a probe break the overview
            return False
        built_dt = _parse_iso(built_at)
        data_dt = _parse_iso(latest)
        if built_dt is None or data_dt is None:
            return False
        return data_dt > built_dt

    # -- internals ---------------------------------------------------------

    def _build(self, market: Market) -> MarketOverview:
        currency = _CURRENCY.get(market, "")
        try:
            result = self._run_screen(market)
        except Exception:  # noqa: BLE001 - any failure -> safe unavailable
            return self._unavailable(market, currency, status=None)

        matches = list(result.matches) if result else []
        status = result.market_status if result else None
        if not matches:
            return self._unavailable(market, currency, status=status)

        advances = sum(1 for m in matches if m.change_percent > 0)
        declines = sum(1 for m in matches if m.change_percent < 0)
        unchanged = sum(1 for m in matches if m.change_percent == 0)
        total_value = round(sum((m.value_traded or 0.0) for m in matches), 2)

        top_gainer = self._mover(max(matches, key=lambda m: m.change_percent))
        top_loser = self._mover(min(matches, key=lambda m: m.change_percent))

        # Top-N movers grid (Gainers / Losers / Most Active), derived from the
        # same universe screen. Real rows only -- never promote mock fallbacks.
        live = [m for m in matches if getattr(m, "data_source", "live") != "mock"]
        pool = live or matches
        gainers = sorted(pool, key=lambda m: m.change_percent, reverse=True)
        losers = sorted(pool, key=lambda m: m.change_percent)
        active = sorted(pool, key=lambda m: (m.value_traded or 0.0), reverse=True)
        top_gainers = tuple(
            self._mover(m) for m in gainers[:_MOVERS_LIMIT]
            if m.change_percent > 0
        )
        top_losers = tuple(
            self._mover(m) for m in losers[:_MOVERS_LIMIT]
            if m.change_percent < 0
        )
        most_active = tuple(
            self._mover(m) for m in active[:_MOVERS_LIMIT]
            if (m.value_traded or 0.0) > 0
        )

        foreign = self._foreign_flow(market)

        return MarketOverview(
            market=market,
            available=True,
            status=status,
            advances=advances,
            declines=declines,
            unchanged=unchanged,
            total_symbols=len(matches),
            total_value_traded=total_value,
            currency=currency,
            top_gainer=top_gainer,
            top_loser=top_loser,
            top_gainers=top_gainers,
            top_losers=top_losers,
            most_active=most_active,
            foreign_flow=foreign,
            updated_at=_now_iso(),
        )

    @staticmethod
    def _mover(m: ScreenerMatch) -> MoverRef:
        return MoverRef(
            symbol=m.symbol,
            name=m.name or m.symbol,
            price=round(m.price, 2),
            change_percent=round(m.change_percent, 2),
            value_traded=round(m.value_traded or 0.0, 2),
        )

    def _unavailable(
        self, market: Market, currency: str, *, status: Optional[str]
    ) -> MarketOverview:
        return MarketOverview(
            market=market,
            available=False,
            status=status,
            advances=None,
            declines=None,
            unchanged=None,
            total_symbols=None,
            total_value_traded=None,
            currency=currency,
            top_gainer=None,
            top_loser=None,
            # IDX still surfaces the (unavailable) foreign-flow row.
            foreign_flow=self._foreign_flow(market),
            updated_at=_now_iso(),
        )
