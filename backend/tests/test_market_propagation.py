"""Market propagation: a request's market must reach the engine and build the
correct Yahoo ticker.

Regression for the bug where an HKEX symbol (e.g. 03417) was routed as IDX and
fetched as 03417.JK instead of 3417.HK ("predict fell back to mock for
03417.JK"). We spy on the engine's fetcher to capture the exact ticker that the
route resolved, proving the request market is honored end-to-end and never
silently defaulted to IDX/.JK when provided.
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import main
from app.engine import AnalysisEngine, yf_symbol
from app.models import Market
from app.universe import UniverseRepository

_UNIV_DIR = Path(tempfile.mkdtemp(prefix="tw_prop_univ_"))
for _stem in ("idx", "hkex", "kospi", "kosdaq"):
    (_UNIV_DIR / f"{_stem}.csv").write_text(
        "symbol,name\n" + "".join(f"SYM{i:02d},Co {i}\n" for i in range(4))
    )


class _SpyEngine(AnalysisEngine):
    """Records every ticker the engine tries to fetch (then forces fallback)."""

    def __init__(self):
        self.tickers: list[str] = []

        def fetch(ticker, period, interval):
            self.tickers.append(ticker)
            raise ConnectionError("no network in tests")

        super().__init__(
            fetcher=fetch,
            universe=UniverseRepository(universe_dir=_UNIV_DIR),
        )


@pytest.fixture()
def spy(monkeypatch):
    engine = _SpyEngine()
    monkeypatch.setattr(main, "engine", engine)
    return engine


@pytest.fixture()
def client():
    return TestClient(main.app)


# --- yf_symbol unit truth (no .JK for HKEX) ---------------------------------

def test_hkex_03417_resolves_to_sehk_3417_not_jk():
    assert yf_symbol("03417", Market.HKEX) == "3417.HK"
    assert not yf_symbol("03417", Market.HKEX).endswith(".JK")


# --- analyze route honors the request market --------------------------------

def test_analyze_hkex_builds_hk_ticker(spy, client):
    r = client.get("/v1/analyze/03417", params={"market": "HKEX"})
    assert r.status_code == 200
    assert r.json()["market"] == "HKEX"
    assert "3417.HK" in spy.tickers
    assert all(not t.endswith(".JK") for t in spy.tickers)


def test_analyze_idx_builds_jk_ticker(spy, client):
    r = client.get("/v1/analyze/BBCA", params={"market": "IDX"})
    assert r.status_code == 200
    assert r.json()["market"] == "IDX"
    assert "BBCA.JK" in spy.tickers


# --- predict_weekly route honors the request market -------------------------

def test_predict_weekly_hkex_builds_hk_ticker(spy, client):
    # This is the exact failing log line: predict for 03417 must NOT be .JK.
    r = client.get("/v1/predict_weekly/03417", params={"market": "HKEX"})
    assert r.status_code == 200
    assert "3417.HK" in spy.tickers
    assert all(not t.endswith(".JK") for t in spy.tickers)


def test_predict_weekly_idx_builds_jk_ticker(spy, client):
    r = client.get("/v1/predict_weekly/BBCA", params={"market": "IDX"})
    assert r.status_code == 200
    assert "BBCA.JK" in spy.tickers


# --- IBKR order routing must map HKEX -> SEHK/3417 (never .JK) ---------------

def test_ibkr_preview_hkex_03417_maps_to_sehk_3417():
    from app.brokers.ibkr_client import MockIBKRClient
    from app.brokers.ibkr_config import IBKRConfig
    from app.brokers.ibkr_service import IBKRService
    from app.broker.models import OrderSide, OrderType

    svc = IBKRService(config=IBKRConfig(),
                      client=MockIBKRClient(connected=True))
    pv = svc.preview("03417", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 5.0)
    # Confirmation token exists and the order maps to the HK exchange code.
    assert pv.confirmation_token
    spec, _, _ = svc._validate("03417", Market.HKEX, OrderSide.BUY, 100,
                               OrderType.LIMIT, 5.0)
    assert spec["exchange"] == "SEHK"
    assert spec["currency"] == "HKD"
    assert spec["symbol"] == "3417"  # leading zero stripped, no .JK


def test_ibkr_place_hkex_03417_maps_to_sehk_3417():
    from app.brokers.ibkr_client import MockIBKRClient
    from app.brokers.ibkr_config import IBKRConfig
    from app.brokers.ibkr_service import IBKRService
    from app.broker.models import OrderSide, OrderType

    client = MockIBKRClient(connected=True)
    svc = IBKRService(config=IBKRConfig(), client=client)
    pv = svc.preview("03417", Market.HKEX, OrderSide.BUY, 100,
                     OrderType.LIMIT, 5.0)
    res = svc.place("03417", Market.HKEX, OrderSide.BUY, 100,
                    OrderType.LIMIT, 5.0, pv.confirmation_token)
    assert res.status == "SUBMITTED"
    placed = client.orders()[-1]
    # The symbol sent to IBKR is the HK code 3417 (leading zero stripped),
    # never a .JK-style symbol.
    assert placed["symbol"] == "3417"
    assert ".JK" not in placed["symbol"]
