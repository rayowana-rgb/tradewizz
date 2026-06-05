"""Market status + data timestamp in AnalysisResult.highlights.

Only the leading two highlight lines are exercised here; scoring/signal/etc.
are covered elsewhere and unchanged.
"""

from datetime import datetime
from zoneinfo import ZoneInfo

import numpy as np
import pandas as pd

from app.engine import (
    AnalysisEngine,
    _is_market_open,
    _market_status_lines,
)
from app.models import Market

JKT = ZoneInfo("Asia/Jakarta")
LAST_BAR = datetime(2026, 6, 4, tzinfo=JKT)


# --- _is_market_open --------------------------------------------------------

def test_open_during_weekday_hours():
    # Friday 10:30 WIB -> open.
    assert _is_market_open(Market.IDX, datetime(2026, 6, 5, 10, 30, tzinfo=JKT))


def test_open_at_boundaries():
    assert _is_market_open(Market.IDX, datetime(2026, 6, 5, 9, 0, tzinfo=JKT))
    assert _is_market_open(Market.IDX, datetime(2026, 6, 5, 16, 0, tzinfo=JKT))


def test_closed_before_open_and_after_close():
    assert not _is_market_open(Market.IDX, datetime(2026, 6, 5, 8, 30, tzinfo=JKT))
    assert not _is_market_open(Market.IDX, datetime(2026, 6, 5, 16, 30, tzinfo=JKT))


def test_closed_on_weekend():
    sat = datetime(2026, 6, 6, 11, 0, tzinfo=JKT)
    sun = datetime(2026, 6, 7, 11, 0, tzinfo=JKT)
    assert not _is_market_open(Market.IDX, sat)
    assert not _is_market_open(Market.IDX, sun)


# --- _market_status_lines ---------------------------------------------------

def test_open_lines_format():
    now = datetime(2026, 6, 5, 10, 30, tzinfo=JKT)
    lines = _market_status_lines(Market.IDX, LAST_BAR, now)
    assert lines[0] == "Market Status: OPEN"
    assert lines[1] == "Data Timestamp: 05 Jun 2026 10:30 WIB"


def test_closed_lines_use_last_data_date():
    now = datetime(2026, 6, 5, 16, 30, tzinfo=JKT)  # after close
    lines = _market_status_lines(Market.IDX, LAST_BAR, now)
    assert lines[0] == "Market Status: CLOSED"
    assert lines[1] == "Last Market Close: 04 Jun 2026"


def test_weekend_lines_closed():
    now = datetime(2026, 6, 6, 11, 0, tzinfo=JKT)  # Saturday
    lines = _market_status_lines(Market.IDX, LAST_BAR, now)
    assert lines[0] == "Market Status: CLOSED"
    assert lines[1].startswith("Last Market Close: ")


def test_closed_falls_back_to_now_without_last_date():
    now = datetime(2026, 6, 6, 11, 0, tzinfo=JKT)  # Saturday, no last_data_date
    lines = _market_status_lines(Market.IDX, None, now)
    assert lines == ["Market Status: CLOSED", "Last Market Close: 06 Jun 2026"]


# --- _highlights prepends the status lines ----------------------------------

def _ind():
    return {
        "close": 153.0, "sma20": 192.5, "volume": 631_700.0,
        "vol_mean_20": 458_900.0, "value_traded": 96_700_000.0,
        "volume_ratio": 1.38, "atr_pct": 8.20,
    }


def test_highlights_prepend_status_then_metrics():
    eng = AnalysisEngine(fetcher=lambda t, p, i: None)
    open_now = datetime(2026, 6, 5, 10, 30, tzinfo=JKT)
    hl = eng._highlights(_ind(), Market.IDX, last_data_date=open_now)
    # Status lines come first, in order, then the existing metrics.
    assert hl[0] == "Market Status: OPEN"
    assert hl[1].startswith("Data Timestamp: ")
    assert hl[2] == "Current Price: Rp153.00"
    assert hl[3] == "20-Day Average Price: Rp192.50"
    # Existing investor metrics still present and unchanged.
    text = " | ".join(hl)
    for label in ["Today's Volume", "20-Day Average Volume",
                  "Value Traded Today", "Volume Ratio", "ATR"]:
        assert label in text
    # No raw technicals leaked back in.
    for banned in ["RSI(14)", "EMA20", "SMA200", "MACD hist"]:
        assert banned not in text


def test_full_highlights_count_is_nine():
    # 2 status lines + 7 metric lines.
    eng = AnalysisEngine(fetcher=lambda t, p, i: None)
    hl = eng._highlights(_ind(), Market.IDX)
    assert len(hl) == 9
