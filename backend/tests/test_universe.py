"""Universe loader tests (CSV + Excel, no network)."""

import pandas as pd
import pytest

from app.models import Market
from app.universe import UniverseRepository, _entries_from_df


def _write_csv(path, text):
    path.write_text(text)


def test_loads_csv_with_symbol_and_name(tmp_path):
    _write_csv(
        tmp_path / "idx.csv",
        "symbol,name\nBBCA,Bank Central Asia\nTLKM,Telkom Indonesia\n",
    )
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.IDX) == ["BBCA", "TLKM"]
    assert repo.names(Market.IDX)["BBCA"] == "Bank Central Asia"


def test_alternative_symbol_column_names(tmp_path):
    _write_csv(tmp_path / "hkex.csv", "ticker\n0700\n9988\n")
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.HKEX) == ["0700", "9988"]


def test_headerless_single_column(tmp_path):
    # First row becomes the header in pandas; with one column we still treat it
    # as a symbol column, so only data rows after it are symbols.
    df = _entries_from_df(pd.DataFrame({"005930": ["000660", "373220"]}))
    assert [e.symbol for e in df] == ["000660", "373220"]


def test_normalizes_and_dedupes(tmp_path):
    _write_csv(
        tmp_path / "kospi.csv",
        "symbol\n005930\n005930\n  000660 \nnan\n",
    )
    repo = UniverseRepository(universe_dir=tmp_path)
    syms = repo.symbols(Market.KOSPI)
    assert syms == ["005930", "000660"]  # deduped, trimmed; blank dropped


def test_excel_loading(tmp_path):
    path = tmp_path / "kosdaq.xlsx"
    pd.DataFrame(
        {"symbol": ["247540", "086520"], "name": ["EcoPro BM", "EcoPro"]}
    ).to_excel(path, index=False)
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.KOSDAQ) == ["247540", "086520"]
    assert repo.names(Market.KOSDAQ)["086520"] == "EcoPro"


def test_csv_preferred_over_excel(tmp_path):
    _write_csv(tmp_path / "idx.csv", "symbol\nFROMCSV\n")
    pd.DataFrame({"symbol": ["FROMXLSX"]}).to_excel(
        tmp_path / "idx.xlsx", index=False
    )
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.IDX) == ["FROMCSV"]


def test_missing_file_returns_empty(tmp_path):
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.IDX) == []


def test_bad_file_returns_empty(tmp_path):
    # No recognizable symbol column.
    _write_csv(tmp_path / "idx.csv", "foo,bar\n1,2\n3,4\n")
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.IDX) == []


def test_caching_and_reload(tmp_path):
    csv = tmp_path / "idx.csv"
    _write_csv(csv, "symbol\nAAA\n")
    repo = UniverseRepository(universe_dir=tmp_path)
    assert repo.symbols(Market.IDX) == ["AAA"]

    # Change on disk -> cached value persists until reload().
    _write_csv(csv, "symbol\nBBB\n")
    assert repo.symbols(Market.IDX) == ["AAA"]
    repo.reload()
    assert repo.symbols(Market.IDX) == ["BBB"]


def test_shipped_universes_are_present():
    """The repo ships starter universes for all four markets."""
    repo = UniverseRepository()  # default data/universe dir
    for market in Market:
        assert len(repo.symbols(market)) > 0, f"empty universe for {market.value}"
