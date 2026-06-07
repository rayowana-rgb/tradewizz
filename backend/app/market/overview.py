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


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass(frozen=True)
class MoverRef:
    symbol: str
    name: str
    price: float
    change_percent: float

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "name": self.name,
            "price": self.price,
            "change_percent": self.change_percent,
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
    ):
        # run_screen(market) -> full-universe ScreenerResult (real data, cached
        # via the screener-cache wiring in main.py).
        self._run_screen = run_screen
        self._ttl = ttl_seconds
        self._clock = clock
        self._foreign_flow = foreign_flow
        self._lock = threading.Lock()
        self._cache: Dict[Market, tuple[float, MarketOverview]] = {}

    # -- public ------------------------------------------------------------

    def get(self, market: Market) -> MarketOverview:
        with self._lock:
            entry = self._cache.get(market)
            if entry is not None:
                fetched_at, overview = entry
                if 0 <= (self._clock() - fetched_at) < self._ttl:
                    return overview
        overview = self._build(market)
        with self._lock:
            self._cache[market] = (self._clock(), overview)
        return overview

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
