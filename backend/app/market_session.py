"""Trading-day / market-session helpers used by the cache layer.

Provides:
  * ``get_market_session_state(market, now)`` -> one of
    ``PRE_MARKET`` / ``OPEN`` / ``POST_MARKET`` / ``CLOSED``.
  * ``current_trading_date(market, now)`` -> the trading date a cache entry
    should be keyed on (market-local calendar date of the *current or most
    recent* session). This is what makes the OHLCV cache trading-day-aware:
    when the date rolls to a new session, the key/expectation changes and
    yesterday's entry is no longer served.

Schedules are simple weekday windows (no exchange holiday calendar). Supported:
IDX, HKEX, KOSPI, KOSDAQ and US (NYSE/Nasdaq). US is accepted as a string code
so this helper covers it per the requirements even though the app's ``Market``
enum currently lists the four Asian markets.

This module imports nothing from scoring / indicators / ML / portfolio / broker
code. It only describes session timing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, time as dtime
from enum import Enum
from typing import Optional, Union
from zoneinfo import ZoneInfo


class MarketSessionState(str, Enum):
    PRE_MARKET = "PRE_MARKET"
    OPEN = "OPEN"
    POST_MARKET = "POST_MARKET"
    CLOSED = "CLOSED"


@dataclass(frozen=True)
class _Session:
    tz: str
    # All times are market-local clock times (HH, MM).
    pre_open: dtime    # pre-market window starts
    open: dtime        # regular session opens
    close: dtime       # regular session closes
    post_close: dtime  # post-market window ends


# Weekday schedules. Pre/post windows are approximate but enough to classify
# PRE_MARKET vs OPEN vs POST_MARKET vs CLOSED for cache decisions.
_SESSIONS = {
    "IDX": _Session(
        tz="Asia/Jakarta",
        pre_open=dtime(8, 45), open=dtime(9, 0),
        close=dtime(16, 0), post_close=dtime(16, 30),
    ),
    "HKEX": _Session(
        tz="Asia/Hong_Kong",
        pre_open=dtime(9, 0), open=dtime(9, 30),
        close=dtime(16, 0), post_close=dtime(16, 10),
    ),
    "KOSPI": _Session(
        tz="Asia/Seoul",
        pre_open=dtime(8, 30), open=dtime(9, 0),
        close=dtime(15, 30), post_close=dtime(16, 0),
    ),
    "KOSDAQ": _Session(
        tz="Asia/Seoul",
        pre_open=dtime(8, 30), open=dtime(9, 0),
        close=dtime(15, 30), post_close=dtime(16, 0),
    ),
    # US regular session 09:30-16:00 ET, pre 04:00, post to 20:00.
    "US": _Session(
        tz="America/New_York",
        pre_open=dtime(4, 0), open=dtime(9, 30),
        close=dtime(16, 0), post_close=dtime(20, 0),
    ),
    # --- Global market expansion ---
    "JAPAN": _Session(
        tz="Asia/Tokyo",
        pre_open=dtime(8, 45), open=dtime(9, 0),
        close=dtime(15, 0), post_close=dtime(15, 30),
    ),
    "INDIA": _Session(
        tz="Asia/Kolkata",
        pre_open=dtime(9, 0), open=dtime(9, 15),
        close=dtime(15, 30), post_close=dtime(16, 0),
    ),
    "VIETNAM": _Session(
        tz="Asia/Ho_Chi_Minh",
        pre_open=dtime(8, 45), open=dtime(9, 0),
        close=dtime(15, 0), post_close=dtime(15, 15),
    ),
    "SINGAPORE": _Session(
        tz="Asia/Singapore",
        pre_open=dtime(8, 45), open=dtime(9, 0),
        close=dtime(17, 0), post_close=dtime(17, 15),
    ),
}

_DEFAULT = "IDX"


def _market_code(market) -> str:
    """Normalize a Market enum / string to a session key, defaulting to IDX."""
    if market is None:
        return _DEFAULT
    code = getattr(market, "value", market)
    code = str(code).upper()
    if code in _SESSIONS:
        return code
    # Common US aliases.
    if code in ("NYSE", "NASDAQ", "US", "USA"):
        return "US"
    return _DEFAULT


def session_tz(market) -> str:
    return _SESSIONS[_market_code(market)].tz


def market_now(market) -> datetime:
    """Current time in the market's local timezone."""
    return datetime.now(ZoneInfo(session_tz(market)))


def _is_weekday(d: date) -> bool:
    return d.weekday() < 5  # Mon-Fri


def get_market_session_state(
    market, now: Optional[datetime] = None
) -> MarketSessionState:
    """Classify the current market session.

    Returns PRE_MARKET / OPEN / POST_MARKET / CLOSED. Weekends and times
    outside the pre..post window are CLOSED.
    """
    sess = _SESSIONS[_market_code(market)]
    cur = now if now is not None else market_now(market)
    if not _is_weekday(cur.date()):
        return MarketSessionState.CLOSED
    t = cur.timetz().replace(tzinfo=None) if cur.tzinfo else cur.time()
    if t < sess.pre_open:
        return MarketSessionState.CLOSED
    if t < sess.open:
        return MarketSessionState.PRE_MARKET
    if t <= sess.close:
        return MarketSessionState.OPEN
    if t <= sess.post_close:
        return MarketSessionState.POST_MARKET
    return MarketSessionState.CLOSED


def is_session_open(market, now: Optional[datetime] = None) -> bool:
    return get_market_session_state(market, now) is MarketSessionState.OPEN


def current_trading_date(market, now: Optional[datetime] = None) -> date:
    """The trading date a cache entry should be keyed on.

    Rules:
      * During / after a weekday session (>= pre_open) -> today's date.
      * Before pre_open on a weekday, or on a weekend -> the most recent
        prior weekday (the last session whose data is the latest available).

    This is the cache's notion of "which trading day's data is current". When
    it changes (e.g. overnight into a new session day, or Friday->Monday) any
    entry tagged with the old trading date is treated as stale.
    """
    sess = _SESSIONS[_market_code(market)]
    cur = now if now is not None else market_now(market)
    d = cur.date()
    t = cur.timetz().replace(tzinfo=None) if cur.tzinfo else cur.time()

    # Before today's pre-market opens, the "current" data is still the prior
    # session's. Step back to the previous weekday.
    if _is_weekday(d) and t >= sess.pre_open:
        return d
    return _previous_weekday(d if not _is_weekday(d) or t < sess.pre_open else d)


def _previous_weekday(d: date) -> date:
    from datetime import timedelta

    prev = d
    # If d itself is a weekday we still want the *previous* session day when we
    # are before its open; callers pass d for that case. Walk back at least one
    # day, then skip weekends.
    prev = prev - timedelta(days=1)
    while not _is_weekday(prev):
        prev = prev - timedelta(days=1)
    return prev


def trading_date_str(market, now: Optional[datetime] = None) -> str:
    """ISO trading date (YYYY-MM-DD) for cache keys."""
    return current_trading_date(market, now).isoformat()


# Map a Yahoo-style suffix to a market code so the OHLCV cache (which only sees
# a resolved ticker like "BBCA.JK" / "0700.HK") can still pick the right
# session schedule for trading-day awareness.
_SUFFIX_TO_MARKET = {
    ".JK": "IDX",
    ".HK": "HKEX",
    ".KS": "KOSPI",
    ".KQ": "KOSDAQ",
    # --- Global market expansion (US is suffix-less -> default handling) ---
    ".T": "JAPAN",
    ".NS": "INDIA",
    ".VN": "VIETNAM",
    ".SI": "SINGAPORE",
}


def market_for_ticker(ticker: str) -> str:
    """Best-effort market code from a resolved ticker suffix.

    Unknown / suffix-less tickers (e.g. US symbols, indices like ^GSPC) map to
    US, whose long weekday schedule is the most permissive default.
    """
    up = (ticker or "").upper()
    for suffix, code in _SUFFIX_TO_MARKET.items():
        if up.endswith(suffix):
            return code
    return "US"
