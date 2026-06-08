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

    def to_dict(self) -> dict:
        return {
            "market": self.market.value,
            "timezone": self.timezone,
            "currency": self.currency,
            "yahoo_suffix": self.yahoo_suffix,
            "trading_hours": self.trading_hours.to_dict(),
            "display_name": self.display_name,
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
    ),
    Market.HKEX: MarketConfig(
        market=Market.HKEX,
        timezone="Asia/Hong_Kong",
        currency="HKD",
        yahoo_suffix=".HK",
        trading_hours=TradingHours(dtime(9, 30), dtime(16, 0)),
        display_name="Hong Kong Stock Exchange",
    ),
    Market.KOSPI: MarketConfig(
        market=Market.KOSPI,
        timezone="Asia/Seoul",
        currency="KRW",
        yahoo_suffix=".KS",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 30)),
        display_name="Korea Stock Exchange (KOSPI)",
    ),
    Market.KOSDAQ: MarketConfig(
        market=Market.KOSDAQ,
        timezone="Asia/Seoul",
        currency="KRW",
        yahoo_suffix=".KQ",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 30)),
        display_name="KOSDAQ",
    ),
    # --- Global market expansion ---
    Market.US: MarketConfig(
        market=Market.US,
        timezone="America/New_York",
        currency="USD",
        yahoo_suffix="",  # US symbols are bare (AAPL, MSFT, NVDA).
        trading_hours=TradingHours(dtime(9, 30), dtime(16, 0)),
        display_name="United States (NYSE/Nasdaq/AMEX)",
    ),
    Market.JAPAN: MarketConfig(
        market=Market.JAPAN,
        timezone="Asia/Tokyo",
        currency="JPY",
        yahoo_suffix=".T",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 0)),
        display_name="Japan Exchange Group (Tokyo)",
    ),
    Market.INDIA: MarketConfig(
        market=Market.INDIA,
        timezone="Asia/Kolkata",
        currency="INR",
        yahoo_suffix=".NS",
        trading_hours=TradingHours(dtime(9, 15), dtime(15, 30)),
        display_name="National Stock Exchange of India",
    ),
    Market.VIETNAM: MarketConfig(
        market=Market.VIETNAM,
        timezone="Asia/Ho_Chi_Minh",
        currency="VND",
        yahoo_suffix=".VN",
        trading_hours=TradingHours(dtime(9, 0), dtime(15, 0)),
        display_name="Vietnam (HOSE/HNX/UPCOM)",
    ),
    Market.SINGAPORE: MarketConfig(
        market=Market.SINGAPORE,
        timezone="Asia/Singapore",
        currency="SGD",
        yahoo_suffix=".SI",
        trading_hours=TradingHours(dtime(9, 0), dtime(17, 0)),
        display_name="Singapore Exchange",
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
