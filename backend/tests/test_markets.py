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


def test_kospi_yahoo_mapping():
    assert yf_symbol("005930", Market.KOSPI) == "005930.KS"
    assert yf_symbol("005930.KS", Market.KOSPI) == "005930.KS"


def test_idx_yahoo_mapping_unchanged():
    # IDX logic must not change.
    assert yf_symbol("BBCA", Market.IDX) == "BBCA.JK"


def test_kosdaq_yahoo_mapping():
    assert yf_symbol("247540", Market.KOSDAQ) == "247540.KQ"


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
