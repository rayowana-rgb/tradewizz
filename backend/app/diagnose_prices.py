"""Price-pipeline diagnostics for the Analyze endpoint.

Run: ``python -m app.diagnose_prices``

For BBCA/BBRI/SINI (IDX), compares the cached candle vs a fresh yfinance
download and the price the engine would surface, and reports cache age + market
status. Helps confirm whether a stale intraday cache is causing price drift.
"""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import pandas as pd

from . import indicators
from .cache import _default_cache_dir
from .engine import (
    _impersonating_session,
    _is_market_open,
    _market_now,
    yf_symbol,
)
from .models import Market

SYMBOLS = ["BBCA", "BBRI", "SINI", "BUVA"]


def _key(ticker: str, period="1y", interval="1d") -> str:
    raw = f"{ticker.upper()}|{period}|{interval}"
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def _fresh_download(ticker: str) -> pd.DataFrame:
    import yfinance as yf

    df = yf.download(
        ticker, period="5d", interval="1d", auto_adjust=False,
        progress=False, threads=False, session=_impersonating_session(),
    )
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)
    return df


def main() -> int:
    cache_dir = Path(_default_cache_dir())
    now = _market_now(Market.IDX)
    market_open = _is_market_open(Market.IDX, now)
    print(f"Market (IDX) now: {now:%Y-%m-%d %H:%M %Z} | "
          f"status: {'OPEN' if market_open else 'CLOSED'}\n")

    for sym in SYMBOLS:
        ticker = yf_symbol(sym, Market.IDX)
        key = _key(ticker)
        csv = cache_dir / f"{key}.csv"
        meta = cache_dir / f"{key}.meta.json"

        cache_hit = csv.exists() and meta.exists()
        cached_close = cached_date = age_h = None
        if cache_hit:
            cdf = pd.read_csv(csv, index_col=0, parse_dates=True)
            cached_date = cdf.index[-1].date()
            cached_close = float(cdf["Close"].iloc[-1])
            fetched = json.loads(meta.read_text()).get("fetched_at", 0)
            age_h = (time.time() - fetched) / 3600

        ldf = _fresh_download(ticker)
        live_date = ldf.index[-1].date()
        live_close = float(ldf["Close"].iloc[-1])
        live_adj = float(ldf["Adj Close"].iloc[-1])
        # Price the engine surfaces == compute_all 'close' (latest Close).
        current_price = indicators.compute_all(
            ldf.rename_axis(None)
        ).get("close")

        print(f"Symbol: {sym}")
        print(f"  Latest Candle Date (live):   {live_date}")
        print(f"  Live Close:                  {live_close:,.2f}")
        print(f"  Live Adj Close:              {live_adj:,.2f}")
        print(f"  Current Price Used (engine): {current_price:,.2f}")
        print(f"  cache_hit:                   {cache_hit}")
        if cache_hit:
            drift = "" if cached_close == live_close else "  <-- STALE"
            print(f"  cached_close:                {cached_close:,.2f}{drift}")
            print(f"  cached_candle_date:          {cached_date}")
            print(f"  cache_file_age:              {age_h:.2f}h")
        print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
