"""Global market expansion: universe loading, config, mapping, validation.

Covers US / JAPAN / INDIA / VIETNAM / SINGAPORE added on top of IDX while the
existing scoring / indicators / analysis engine is reused unchanged.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from app.engine import AnalysisEngine, MARKET_SUFFIX, yf_symbol
from app.market_config import (
    MARKET_CONFIGS,
    SUFFIX_TO_MARKET,
    currency,
    get_config,
    yahoo_suffix,
)
from app.market_session import market_for_ticker
from app.models import Market
from app.universe import UniverseRepository
from app.universe_validation import REQUIRED_MARKETS, validate_universes

NEW_MARKETS = [
    Market.US,
    Market.JAPAN,
    Market.INDIA,
    Market.VIETNAM,
    Market.SINGAPORE,
]


# --------------------------------------------------------------------------- #
# Market enum + configuration                                                 #
# --------------------------------------------------------------------------- #
def test_market_enum_has_new_markets():
    for m in NEW_MARKETS:
        assert isinstance(m, Market)
    assert {m.value for m in NEW_MARKETS} == {
        "US", "JAPAN", "INDIA", "VIETNAM", "SINGAPORE"
    }


@pytest.mark.parametrize(
    "market,tz,cur,suffix",
    [
        (Market.US, "America/New_York", "USD", ""),
        (Market.JAPAN, "Asia/Tokyo", "JPY", ".T"),
        (Market.INDIA, "Asia/Kolkata", "INR", ".NS"),
        (Market.VIETNAM, "Asia/Ho_Chi_Minh", "VND", ".VN"),
        (Market.SINGAPORE, "Asia/Singapore", "SGD", ".SI"),
    ],
)
def test_market_config_values(market, tz, cur, suffix):
    cfg = get_config(market)
    assert cfg.timezone == tz
    assert cfg.currency == cur
    assert cfg.yahoo_suffix == suffix
    assert currency(market) == cur
    assert yahoo_suffix(market) == suffix
    # trading_hours + display_name are populated.
    assert cfg.trading_hours.open < cfg.trading_hours.close
    assert cfg.display_name


def test_idx_config_unchanged():
    cfg = get_config(Market.IDX)
    assert cfg.timezone == "Asia/Jakarta"
    assert cfg.currency == "IDR"
    assert cfg.yahoo_suffix == ".JK"


def test_engine_suffix_map_matches_config():
    # The engine's suffix map derives from the single config source of truth.
    for m, cfg in MARKET_CONFIGS.items():
        assert MARKET_SUFFIX[m] == cfg.yahoo_suffix


# --------------------------------------------------------------------------- #
# Yahoo Finance mapping (unified, no per-market code path)                     #
# --------------------------------------------------------------------------- #
@pytest.mark.parametrize(
    "symbol,market,expected",
    [
        ("AAPL", Market.US, "AAPL"),
        ("MSFT", Market.US, "MSFT"),
        ("NVDA", Market.US, "NVDA"),
        ("7203", Market.JAPAN, "7203.T"),
        ("6758", Market.JAPAN, "6758.T"),
        ("7203.T", Market.JAPAN, "7203.T"),  # idempotent
        ("RELIANCE", Market.INDIA, "RELIANCE.NS"),
        ("INFY", Market.INDIA, "INFY.NS"),
        ("INFY.NS", Market.INDIA, "INFY.NS"),  # idempotent
        ("VCB", Market.VIETNAM, "VCB.VN"),
        ("FPT", Market.VIETNAM, "FPT.VN"),
        ("D05", Market.SINGAPORE, "D05.SI"),
        ("O39", Market.SINGAPORE, "O39.SI"),
        ("BBCA", Market.IDX, "BBCA.JK"),  # unchanged
    ],
)
def test_yahoo_symbol_mapping(symbol, market, expected):
    assert yf_symbol(symbol, market) == expected


@pytest.mark.parametrize(
    "ticker,expected_code",
    [
        ("7203.T", "JAPAN"),
        ("RELIANCE.NS", "INDIA"),
        ("VCB.VN", "VIETNAM"),
        ("D05.SI", "SINGAPORE"),
        ("AAPL", "US"),  # suffix-less -> US default
        ("BBCA.JK", "IDX"),  # unchanged
    ],
)
def test_market_for_ticker_routing(ticker, expected_code):
    assert market_for_ticker(ticker) == expected_code


def test_suffix_to_market_skips_us_empty():
    # US has an empty suffix and must not appear in the reverse lookup.
    assert "" not in SUFFIX_TO_MARKET
    assert SUFFIX_TO_MARKET[".T"] == Market.JAPAN
    assert SUFFIX_TO_MARKET[".SI"] == Market.SINGAPORE


# --------------------------------------------------------------------------- #
# Universe loading from Excel (dynamic, multi-sheet, in-memory cache)          #
# --------------------------------------------------------------------------- #
@pytest.fixture(scope="module")
def repo():
    return UniverseRepository()


@pytest.mark.parametrize("market", NEW_MARKETS)
def test_universe_loads_nonzero(repo, market):
    syms = repo.symbols(market)
    assert len(syms) > 0, f"{market.value} universe is empty"
    # Symbols are stored bare (suffix stripped).
    suffix = yahoo_suffix(market)
    if suffix:
        assert all(not s.endswith(suffix) for s in syms[:50])


@pytest.mark.parametrize("market", NEW_MARKETS)
def test_universe_no_duplicates(repo, market):
    syms = repo.symbols(market)
    assert len(syms) == len(set(syms)), f"{market.value} has duplicate symbols"


def test_universe_counts_split_etf_stock(repo):
    c = repo.counts(Market.US)
    assert c["total"] == c["etf"] + c["stock"]
    assert c["etf"] > 0  # US file has an ETF sheet


@pytest.mark.parametrize(
    "market,symbol",
    [
        (Market.US, "AAPL"),
        (Market.US, "NVDA"),
        (Market.JAPAN, "7203"),
        (Market.JAPAN, "6758"),
        (Market.INDIA, "RELIANCE"),
        (Market.INDIA, "INFY"),
        (Market.VIETNAM, "VCB"),
        (Market.VIETNAM, "FPT"),
        (Market.SINGAPORE, "D05"),
        (Market.SINGAPORE, "O39"),
    ],
)
def test_required_symbols_present(repo, market, symbol):
    assert symbol in set(repo.symbols(market))


def test_universe_in_memory_cache(repo):
    # Second call returns the cached list object (same identity).
    a = repo.entries(Market.SINGAPORE)
    b = repo.entries(Market.SINGAPORE)
    assert a is b


# --------------------------------------------------------------------------- #
# Startup validation                                                          #
# --------------------------------------------------------------------------- #
def test_validation_all_required_ok():
    report = validate_universes(log=False)
    for market in REQUIRED_MARKETS:
        v = report[market]
        assert v.ok, f"{market.value} failed: {v.reasons}"
        assert v.total > 0
        assert v.has_config
        assert v.file_exists
        assert v.total == v.etf + v.stock


# --------------------------------------------------------------------------- #
# Screening engine reuse: same scoring/indicators for new markets             #
# --------------------------------------------------------------------------- #
def _mkdf(close: float, n: int = 200) -> pd.DataFrame:
    idx = pd.date_range(end="2026-06-08", periods=n, freq="D")
    c = np.linspace(close - 20, close, n)
    return pd.DataFrame(
        {"Open": c, "High": c + 1, "Low": c - 1, "Close": c,
         "Volume": np.full(n, 5_000_000.0)},
        index=idx,
    )


def test_same_engine_screens_new_market_and_scores_match_analyze():
    """One unified engine: screener score == analyze score for a new market."""
    prices = {"AAPL": 190.0, "NVDA": 130.0, "MSFT": 420.0}

    def fetch(ticker, period, interval):
        return _mkdf(prices[ticker])  # US tickers are bare

    engine = AnalysisEngine(fetcher=fetch)
    syms = list(prices)
    screen = engine.screen(Market.US, symbols=syms, limit=50)
    by = {m.symbol: m for m in screen.matches}
    assert set(by) == {s.upper() for s in syms}
    for s in syms:
        a = engine.analyze(s, Market.US)
        assert by[s.upper()].score == a.score, f"score mismatch {s}"


@pytest.mark.parametrize(
    "market,symbol,expected_ticker",
    [
        (Market.JAPAN, "7203", "7203.T"),
        (Market.INDIA, "RELIANCE", "RELIANCE.NS"),
        (Market.VIETNAM, "VCB", "VCB.VN"),
        (Market.SINGAPORE, "D05", "D05.SI"),
    ],
)
def test_analyze_uses_unified_fetch_with_suffix(
    market, symbol, expected_ticker
):
    """analyze() routes every market through the one fetch engine + suffix."""
    seen = {}

    def fetch(ticker, period, interval):
        seen["ticker"] = ticker
        return _mkdf(100.0)

    engine = AnalysisEngine(fetcher=fetch)
    res = engine.analyze(symbol, market)
    assert seen["ticker"] == expected_ticker
    assert res.market == market
    assert res.signal in ("BUY", "HOLD", "SELL")
    assert 0.0 <= res.score <= 100.0
