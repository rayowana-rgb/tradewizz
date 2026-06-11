"""Per-market configuration table (single source of truth for metadata).

Each supported market declares:
  * ``timezone``      IANA tz name (e.g. ``America/New_York``).
  * ``currency``      ISO currency code (e.g. ``USD``).
  * ``yahoo_suffix``  yfinance ticker suffix ("" for US bare symbols).
  * ``trading_hours`` market-local regular session window (open, close).
  * ``display_name``  human-friendly exchange name for the UI.

This module is intentionally dependency-light: it imports only ``Market`` and
``datetime.time`` so it can be reused by the universe loader, the engine's
ticker mapper, the session helper, and startup validation WITHOUT creating an
import cycle. It does NOT touch scoring / indicators / ML / portfolio / broker.

The yfinance suffixes here are the ONE place new-market suffixes are declared;
``engine.MARKET_SUFFIX`` and ``universe._MARKET_SUFFIX`` derive from this table
so there is a single unified mapping (no per-market code paths).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import time as dtime
from typing import Dict, Optional

from .models import Market


@dataclass(frozen=True)
class TradingHours:
    """Market-local regular trading session window."""

    open: dtime
    close: dtime

    def to_dict(self) -> dict:
        return {
            "open": self.open.strftime("%H:%M"),
            "close": self.close.strftime("%H:%M"),
        }


@dataclass(frozen=True)
class MarketConfig:
    market: Market
    timezone: str
    currency: str
    yahoo_suffix: str
    trading_hours: TradingHours
    display_name: str
    # Approximate value of 1 unit of this market's currency in IDR
    # (order-of-magnitude only). Used to FX-scale the legacy IDR liquidity /
    # value-traded / cheap-price thresholds into local currency so a non-IDX
    # market is not wiped out by an IDR-sized floor. IDX == 1.0 (no scaling).
    idr_per_unit: float = 1.0

    def to_dict(self) -> dict:
        return {
            "market": self.market.value,
            "timezone": self.timezone,
            "currency": self.currency,
            "yahoo_suffix": self.yahoo_suffix,
            "trading_hours": self.trading_hours.to_dict(),
            "display_name": self.display_name,
            "idr_per_unit": self.idr_per_unit,
        }


# Single source of truth. Suffixes feed engine / universe / session helpers.
MARKET_CONFIGS: Dict[Market, MarketConfig] = {
    Market.IDX: MarketConfig(
        market=Market.IDX,
        timezone="Asia/Jakarta",
        currency="IDR",
        yahoo_suffix=".JK",
        trading_hours=TradingHours(dtime(9, 0), dtime(16, 0)),
        display_name="Indonesia Stock Exchange",
        idr_per_unit=1.0,
    ),
    Market.HKEX: MarketConfig(
        market=Market.HKEX,
        timezone="Asia/Hong_Kong",
        currency="HKD",
        yahoo_suffix=".HK",
        trading_hours=TradingHours(dtime(9, 30), dtime(16, 0)),
        display_name="Hong Kong Stock Exchange",
        idr_per_unit=2000.0,
    ),
    Market.KOSPI: MarketConfig(
        market=Market.KOSPI,
        timezone="Asia/Seoul",
        currency="KRW",
        yahoo_suffix=".KS",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 30)),
        display_name="Korea Stock Exchange (KOSPI)",
        idr_per_unit=12.0,
    ),
    Market.KOSDAQ: MarketConfig(
        market=Market.KOSDAQ,
        timezone="Asia/Seoul",
        currency="KRW",
        yahoo_suffix=".KQ",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 30)),
        display_name="KOSDAQ",
        idr_per_unit=12.0,
    ),
    # --- Global market expansion ---
    Market.US: MarketConfig(
        market=Market.US,
        timezone="America/New_York",
        currency="USD",
        yahoo_suffix="",  # US symbols are bare (AAPL, MSFT, NVDA).
        trading_hours=TradingHours(dtime(9, 30), dtime(16, 0)),
        display_name="United States (NYSE/Nasdaq/AMEX)",
        idr_per_unit=16000.0,
    ),
    Market.JAPAN: MarketConfig(
        market=Market.JAPAN,
        timezone="Asia/Tokyo",
        currency="JPY",
        yahoo_suffix=".T",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 0)),
        display_name="Japan Exchange Group (Tokyo)",
        idr_per_unit=105.0,
    ),
    Market.INDIA: MarketConfig(
        market=Market.INDIA,
        timezone="Asia/Kolkata",
        currency="INR",
        yahoo_suffix=".NS",
        trading_hours=TradingHours(dtime(9, 15), dtime(15, 30)),
        display_name="National Stock Exchange of India",
        idr_per_unit=190.0,
    ),
    Market.VIETNAM: MarketConfig(
        market=Market.VIETNAM,
        timezone="Asia/Ho_Chi_Minh",
        currency="VND",
        yahoo_suffix=".VN",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 0)),
        display_name="Vietnam (HOSE/HNX/UPCOM)",
        idr_per_unit=0.65,
    ),
    Market.SINGAPORE: MarketConfig(
        market=Market.SINGAPORE,
        timezone="Asia/Singapore",
        currency="SGD",
        yahoo_suffix=".SI",
        trading_hours=TradingHours(dtime(9, 0), dtime(17, 0)),
        display_name="Singapore Exchange",
        idr_per_unit=12000.0,
    ),
}


def get_config(market: Market) -> MarketConfig:
    """Return the config for a market (raises KeyError if unconfigured)."""
    return MARKET_CONFIGS[market]


def market_config(market: Market) -> Optional[MarketConfig]:
    """Return the config for a market, or None if unconfigured."""
    return MARKET_CONFIGS.get(market)


def yahoo_suffix(market: Market) -> str:
    """yfinance ticker suffix for a market ("" for US)."""
    cfg = MARKET_CONFIGS.get(market)
    return cfg.yahoo_suffix if cfg else ""


def currency(market: Market) -> str:
    cfg = MARKET_CONFIGS.get(market)
    return cfg.currency if cfg else ""


def idr_per_unit(market: Market) -> float:
    """Approx IDR value of 1 unit of the market's currency (1.0 for IDX/unknown).

    This is the single FX-scaling factor used to translate the legacy IDR
    liquidity / value-traded / cheap-price thresholds into the market's local
    currency. Order-of-magnitude only; it gates liquidity, it does not price.
    """
    cfg = MARKET_CONFIGS.get(market)
    return cfg.idr_per_unit if cfg else 1.0


def timezone_name(market: Market) -> str:
    cfg = MARKET_CONFIGS.get(market)
    return cfg.timezone if cfg else "UTC"


# Suffix -> Market reverse lookup (skips US whose suffix is empty). Used by the
# OHLCV cache to pick a session schedule from a resolved ticker.
SUFFIX_TO_MARKET: Dict[str, Market] = {
    cfg.yahoo_suffix: m
    for m, cfg in MARKET_CONFIGS.items()
    if cfg.yahoo_suffix
}
