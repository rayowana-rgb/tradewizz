"""Symbol mapping for IBKR.

Supports US stocks (SMART/USD) and HKEX (SEHK/HKD). IDX/KOSPI/KOSDAQ are not
mapped (return a clear "not tradable via IBKR" error).

The result is a plain dict spec (symbol/exchange/currency/sec_type) so the
adapter can build an ib_insync Stock contract without importing ib_insync here.
"""

from __future__ import annotations

from typing import Optional

from ..models import Market

NOT_TRADABLE_MSG = "This symbol is not tradable via IBKR."


class IBKRSymbolNotTradable(Exception):
    def __init__(self, message: str = NOT_TRADABLE_MSG):
        super().__init__(message)
        self.message = message


# A small allow-list of US tickers we know map cleanly via SMART routing. The
# adapter also accepts any alphabetic US-style ticker when market is US-style;
# but TradeWizz has no US Market enum yet, so US symbols arrive as HKEX-coded
# digits would not -- US tickers come in via the `market` heuristic below.
_KNOWN_US = {"AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "META", "TSLA"}


def to_ibkr_contract(symbol: str, market: Optional[Market]) -> dict:
    """Return an ib_insync Stock contract spec, or raise IBKRSymbolNotTradable.

    - HKEX numeric codes -> SEHK / HKD (e.g. 700 -> symbol '700').
    - Alphabetic tickers (no TradeWizz market, or a US ticker) -> SMART / USD.
    - IDX / KOSPI / KOSDAQ -> not tradable.
    """
    sym = symbol.strip().upper()
    if not sym:
        raise IBKRSymbolNotTradable("Empty symbol is not tradable via IBKR.")

    if market is Market.HKEX:
        digits = "".join(c for c in sym if c.isdigit())
        if not digits:
            raise IBKRSymbolNotTradable(
                "HKEX symbol must be numeric to trade via IBKR."
            )
        # IBKR HK uses the numeric code without leading zeros.
        return {
            "symbol": str(int(digits)),
            "exchange": "SEHK",
            "currency": "HKD",
            "sec_type": "STK",
        }

    if market in (Market.IDX, Market.KOSPI, Market.KOSDAQ):
        raise IBKRSymbolNotTradable()

    # No market / US-style: treat alphabetic tickers as US stocks (SMART/USD).
    if sym.isalpha():
        return {
            "symbol": sym,
            "exchange": "SMART",
            "currency": "USD",
            "sec_type": "STK",
        }

    raise IBKRSymbolNotTradable()


def is_known_us_ticker(symbol: str) -> bool:
    return symbol.strip().upper() in _KNOWN_US
