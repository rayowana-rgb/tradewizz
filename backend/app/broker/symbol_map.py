"""Map TradeWizz bare symbols + market to Moomoo trade symbols.

Moomoo supports HK / US / CN (etc.) but NOT Indonesia (IDX). KOSPI/KOSDAQ
(Korea) are also not tradable via Moomoo's standard markets, so those return a
clear error instead of guessing.

Moomoo code format: "<MARKET>.<CODE>", e.g. US.AAPL, HK.00700.
"""

from __future__ import annotations

from ..models import Market

# TradeWizz market -> Moomoo TrdMarket / code prefix. None => not tradable.
_MOOMOO_PREFIX = {
    Market.HKEX: "HK",
    # IDX (Indonesia), KOSPI, KOSDAQ are not supported by Moomoo trading.
    Market.IDX: None,
    Market.KOSPI: None,
    Market.KOSDAQ: None,
}

# US is supported by Moomoo but TradeWizz has no US market enum; US tickers can
# still be traded by passing market=HKEX is wrong, so US is handled separately
# only if a US market is later added. For now only HK is mapped.

NOT_TRADABLE_MSG = "This symbol is not tradable via Moomoo."


class SymbolNotTradable(Exception):
    """Raised when a symbol/market cannot be mapped to a Moomoo trade code."""

    def __init__(self, message: str = NOT_TRADABLE_MSG):
        super().__init__(message)
        self.message = message


def is_market_tradable(market: Market) -> bool:
    return _MOOMOO_PREFIX.get(market) is not None


def to_moomoo_code(symbol: str, market: Market) -> str:
    """Resolve a Moomoo trade code, or raise SymbolNotTradable.

    HK codes are zero-padded to 5 digits (e.g. 700 -> 00700) per Moomoo.
    """
    prefix = _MOOMOO_PREFIX.get(market)
    if prefix is None:
        raise SymbolNotTradable()

    sym = symbol.strip().upper()
    if not sym:
        raise SymbolNotTradable("Empty symbol is not tradable via Moomoo.")

    if prefix == "HK":
        # HK uses numeric 5-digit codes.
        digits = "".join(ch for ch in sym if ch.isdigit())
        if not digits:
            raise SymbolNotTradable(
                "HKEX symbol must be numeric to trade via Moomoo."
            )
        return f"HK.{digits.zfill(5)}"

    # Generic prefix.<symbol> (future markets like US).
    return f"{prefix}.{sym}"


def moomoo_currency(market: Market) -> str:
    return {
        Market.HKEX: "HKD",
        Market.IDX: "IDR",
        Market.KOSPI: "KRW",
        Market.KOSDAQ: "KRW",
    }.get(market, "")
