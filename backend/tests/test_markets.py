"""HKEX / KOSPI market enablement: Yahoo symbol mapping + Moomoo tradability.

Does not change IDX logic, scoring, or the Yahoo data source.
"""

import pytest

from app.broker.symbol_map import (
    SymbolNotTradable,
    is_market_tradable,
    to_moomoo_code,
)
from app.engine import yf_symbol
from app.models import Market
from app.universe import UniverseRepository


# --- Yahoo symbol mapping ---------------------------------------------------

def test_hkex_yahoo_mapping():
    assert yf_symbol("0700", Market.HKEX) == "0700.HK"
    # Idempotent: already-suffixed stays.
    assert yf_symbol("0700.HK", Market.HKEX) == "0700.HK"


def test_hkex_leading_zero_normalized_to_4_digits():
    # Yahoo expects a 4-digit HK code: 02331 -> 2331.HK (the reported bug),
    # 2331 -> 2331.HK, 700 -> 0700.HK, 0700 -> 0700.HK.
    assert yf_symbol("02331", Market.HKEX) == "2331.HK"
    assert yf_symbol("2331", Market.HKEX) == "2331.HK"
    assert yf_symbol("0700", Market.HKEX) == "0700.HK"
    assert yf_symbol("700", Market.HKEX) == "0700.HK"
    assert yf_symbol("9988", Market.HKEX) == "9988.HK"


def test_kospi_yahoo_mapping():
    assert yf_symbol("005930", Market.KOSPI) == "005930.KS"
    assert yf_symbol("005930.KS", Market.KOSPI) == "005930.KS"


def test_kospi_pads_to_6_digits():
    # Korean codes must keep/restore 6 digits: 5930 -> 005930.KS.
    assert yf_symbol("5930", Market.KOSPI) == "005930.KS"


def test_idx_yahoo_mapping_unchanged():
    # IDX logic must not change (alphabetic ticker, no numeric normalization).
    assert yf_symbol("BBCA", Market.IDX) == "BBCA.JK"
    assert yf_symbol("GOTO", Market.IDX) == "GOTO.JK"


def test_kosdaq_yahoo_mapping():
    assert yf_symbol("247540", Market.KOSDAQ) == "247540.KQ"


def test_kosdaq_codes_normalize_to_6_digits():
    assert yf_symbol("035720", Market.KOSDAQ) == "035720.KQ"
    assert yf_symbol("35720", Market.KOSDAQ) == "035720.KQ"


def test_yf_symbol_idempotent_for_normalized_inputs():
    # Re-applying yf_symbol to its own output is stable.
    assert yf_symbol(yf_symbol("02331", Market.HKEX), Market.HKEX) == "2331.HK"
    assert yf_symbol(yf_symbol("5930", Market.KOSPI), Market.KOSPI) == "005930.KS"


def test_moomoo_hk_format_unchanged_5_digits():
    # Moomoo HK trading code stays 5-digit regardless of Yahoo normalization.
    assert to_moomoo_code("02331", Market.HKEX) == "HK.02331"
    assert to_moomoo_code("2331", Market.HKEX) == "HK.02331"
    assert to_moomoo_code("0700", Market.HKEX) == "HK.00700"


# --- Moomoo tradability -----------------------------------------------------

def test_hkex_is_tradable_via_moomoo():
    assert is_market_tradable(Market.HKEX) is True
    assert to_moomoo_code("0700", Market.HKEX) == "HK.00700"


def test_idx_not_tradable_via_moomoo():
    assert is_market_tradable(Market.IDX) is False
    with pytest.raises(SymbolNotTradable):
        to_moomoo_code("BBCA", Market.IDX)


def test_kospi_not_tradable_unless_supported():
    # KOSPI is not assumed tradable via Moomoo.
    assert is_market_tradable(Market.KOSPI) is False
    with pytest.raises(SymbolNotTradable):
        to_moomoo_code("005930", Market.KOSPI)


def test_kosdaq_not_tradable():
    assert is_market_tradable(Market.KOSDAQ) is False


# --- universes load for the enabled markets ---------------------------------

def test_hkex_and_kospi_universes_load():
    repo = UniverseRepository()
    assert len(repo.symbols(Market.HKEX)) > 0
    assert len(repo.symbols(Market.KOSPI)) > 0
    # HKEX universe symbols are numeric codes (map cleanly to Yahoo .HK).
    assert all(s.isdigit() for s in repo.symbols(Market.HKEX)[:20])
    # KOSPI universe symbols are 6-digit codes (map to Yahoo .KS).
    assert all(s.isdigit() for s in repo.symbols(Market.KOSPI)[:20])


# --- analyze does not produce placeholder for normalized symbols ------------

def _ohlcv(n=300):
    import numpy as np
    import pandas as pd

    close = 100 + np.arange(n) * 1.0
    return pd.DataFrame({
        "Open": close, "High": close + 1, "Low": close - 1, "Close": close,
        "Volume": np.full(n, 1000.0),
    })


def _fetch_capture():
    """A fetcher that records the ticker it was asked for and returns data."""
    seen = {}

    def fetch(ticker, period, interval):
        seen["ticker"] = ticker
        return _ohlcv()

    return fetch, seen


def test_analyze_02331_hkex_fetches_normalized_ticker_no_placeholder():
    from app.engine import AnalysisEngine

    fetch, seen = _fetch_capture()
    eng = AnalysisEngine(fetcher=fetch)
    res = eng.analyze("02331", Market.HKEX)
    # The engine fetched the normalized Yahoo ticker, not 02331.HK.
    assert seen["ticker"] == "2331.HK"
    # Real engine output (not the mock-fallback placeholder).
    assert "placeholder" not in res.summary.lower()
    text = " | ".join(res.highlights)
    assert "Current Price" in text
    assert "Today's Volume" in text
    assert "Value Traded Today" in text


def test_analyze_5930_kospi_fetches_padded_ticker():
    from app.engine import AnalysisEngine

    fetch, seen = _fetch_capture()
    eng = AnalysisEngine(fetcher=fetch)
    res = eng.analyze("5930", Market.KOSPI)
    assert seen["ticker"] == "005930.KS"
    assert "placeholder" not in res.summary.lower()


def test_analyze_kosdaq_fetches_kq_ticker():
    from app.engine import AnalysisEngine

    fetch, seen = _fetch_capture()
    eng = AnalysisEngine(fetcher=fetch)
    res = eng.analyze("035720", Market.KOSDAQ)
    assert seen["ticker"] == "035720.KQ"
    assert "placeholder" not in res.summary.lower()
