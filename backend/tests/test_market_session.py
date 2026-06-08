"""Market-session state + trading-date helpers (req 4)."""

from datetime import datetime
from zoneinfo import ZoneInfo

from app.market_session import (
    MarketSessionState,
    current_trading_date,
    get_market_session_state,
    market_for_ticker,
)
from app.models import Market

JKT = ZoneInfo("Asia/Jakarta")
HKT = ZoneInfo("Asia/Hong_Kong")
ET = ZoneInfo("America/New_York")


# --- session state ---------------------------------------------------------

def test_idx_open_midsession():
    s = get_market_session_state(Market.IDX, datetime(2026, 6, 8, 11, 0, tzinfo=JKT))
    assert s is MarketSessionState.OPEN


def test_idx_pre_market():
    s = get_market_session_state(Market.IDX, datetime(2026, 6, 8, 8, 50, tzinfo=JKT))
    assert s is MarketSessionState.PRE_MARKET


def test_idx_post_market():
    s = get_market_session_state(Market.IDX, datetime(2026, 6, 8, 16, 15, tzinfo=JKT))
    assert s is MarketSessionState.POST_MARKET


def test_idx_closed_overnight():
    s = get_market_session_state(Market.IDX, datetime(2026, 6, 8, 22, 0, tzinfo=JKT))
    assert s is MarketSessionState.CLOSED


def test_weekend_is_closed():
    # 2026-06-06 is a Saturday.
    s = get_market_session_state(Market.IDX, datetime(2026, 6, 6, 11, 0, tzinfo=JKT))
    assert s is MarketSessionState.CLOSED


def test_hkex_open_and_us_open():
    assert get_market_session_state(
        Market.HKEX, datetime(2026, 6, 8, 10, 0, tzinfo=HKT)
    ) is MarketSessionState.OPEN
    assert get_market_session_state(
        "US", datetime(2026, 6, 8, 10, 0, tzinfo=ET)
    ) is MarketSessionState.OPEN


def test_us_pre_and_post_market():
    assert get_market_session_state(
        "US", datetime(2026, 6, 8, 5, 0, tzinfo=ET)
    ) is MarketSessionState.PRE_MARKET
    assert get_market_session_state(
        "US", datetime(2026, 6, 8, 18, 0, tzinfo=ET)
    ) is MarketSessionState.POST_MARKET


# --- trading date ----------------------------------------------------------

def test_trading_date_during_session_is_today():
    d = current_trading_date(Market.IDX, datetime(2026, 6, 8, 11, 0, tzinfo=JKT))
    assert d.isoformat() == "2026-06-08"


def test_trading_date_after_close_is_today():
    d = current_trading_date(Market.IDX, datetime(2026, 6, 8, 22, 0, tzinfo=JKT))
    assert d.isoformat() == "2026-06-08"


def test_trading_date_before_open_is_prior_weekday():
    # Monday 06:00 (before pre-open) -> prior session = Friday 2026-06-05.
    d = current_trading_date(Market.IDX, datetime(2026, 6, 8, 6, 0, tzinfo=JKT))
    assert d.isoformat() == "2026-06-05"


def test_trading_date_weekend_is_prior_friday():
    # Saturday -> Friday.
    d = current_trading_date(Market.IDX, datetime(2026, 6, 6, 11, 0, tzinfo=JKT))
    assert d.isoformat() == "2026-06-05"


def test_trading_date_rolls_to_new_day_after_open():
    # Across two consecutive trading sessions the date advances.
    t = current_trading_date(Market.IDX, datetime(2026, 6, 8, 17, 0, tzinfo=JKT))
    t1 = current_trading_date(Market.IDX, datetime(2026, 6, 9, 10, 0, tzinfo=JKT))
    assert t.isoformat() == "2026-06-08"
    assert t1.isoformat() == "2026-06-09"
    assert t1 != t


# --- ticker -> market ------------------------------------------------------

def test_market_for_ticker_suffixes():
    assert market_for_ticker("BBCA.JK") == "IDX"
    assert market_for_ticker("0700.HK") == "HKEX"
    assert market_for_ticker("005930.KS") == "KOSPI"
    assert market_for_ticker("035720.KQ") == "KOSDAQ"
    assert market_for_ticker("AAPL") == "US"
