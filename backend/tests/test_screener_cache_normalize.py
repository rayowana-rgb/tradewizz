"""Lapis 3: cache-key normalization for /v1/screen/{market}.

Offline + deterministic: the engine is replaced with a counting fake, so we
verify the route caches the engine at the SUPERSET (limit=MAX_LIMIT,
min_score=0) and applies the user's limit/min_score in memory. Many param
variants must collapse onto ONE heavy engine run while each response is sliced
correctly.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

import functools

from app import main
from app.models import Market, ScreenerMatch, ScreenerResult
from app.screener_cache import InMemoryScreenerSnapshotStore
from app.screener_cache.service import ScreenerCacheService

client = TestClient(main.app)

HK = ZoneInfo("Asia/Hong_Kong")
CLOSED_TIME = datetime(2026, 6, 8, 18, 0, tzinfo=HK)  # Mon 18:00 HKT -> CLOSED


def _superset(n: int = 20) -> ScreenerResult:
    """A wide, pre-sorted (score desc) result like the engine's superset run."""
    matches = [
        ScreenerMatch(
            symbol=f"S{i:02d}",
            name=f"Name {i}",
            score=float(100 - i * 5),  # 100, 95, 90, ... distinct, desc
            signal="BUY",
            price=100.0 + i,
            change_percent=1.0,
            value_traded=1e9,
        )
        for i in range(n)
    ]
    return ScreenerResult(
        market=Market.HKEX,
        matches=matches,
        generated_at="2026-06-08T18:30:00+00:00",
        total_count=n,
        returned_count=n,
        limit=200,
    )


@pytest.fixture(autouse=True)
def _isolate(monkeypatch):
    # Fresh in-memory snapshot store so keys don't leak across tests / disk.
    monkeypatch.setattr(
        main, "screener_snapshot_store", InMemoryScreenerSnapshotStore()
    )
    # Neutralize the live data-freshness probes so a saved snapshot is reused
    # deterministically (otherwise the live cache registry from other modules
    # reports a "newer" candle and forces a rebuild each call -- a test-only
    # artifact, not production behavior).
    NeutralService = functools.partial(
        ScreenerCacheService,
        latest_data_timestamp=lambda _m: None,
        latest_write_timestamp=None,
    )
    monkeypatch.setattr(main, "ScreenerCacheService", NeutralService)
    # Pin the market clock to CLOSED so the cache runs+saves deterministically.
    main.set_screener_now_override(lambda _m: CLOSED_TIME)
    yield
    main.set_screener_now_override(None)


def _install_counting_engine(monkeypatch):
    calls = {"n": 0, "limits": [], "min_scores": []}

    def fake_screen(market, *, limit, min_score, categories, min_value_traded):
        calls["n"] += 1
        calls["limits"].append(limit)
        calls["min_scores"].append(min_score)
        return _superset()

    monkeypatch.setattr(main.engine, "screen", fake_screen)
    # Keep the cache from re-running due to data-freshness probes.
    return calls


def test_varied_limit_and_min_score_collapse_to_one_engine_run(monkeypatch):
    calls = _install_counting_engine(monkeypatch)

    # Three different limits + min_scores -> still ONE heavy engine run.
    a = client.get("/v1/screen/HKEX", params={"limit": 5}).json()
    b = client.get("/v1/screen/HKEX", params={"limit": 50}).json()
    c = client.get(
        "/v1/screen/HKEX", params={"limit": 200, "min_score": 80}
    ).json()

    assert calls["n"] == 1  # collapsed onto a single cached superset run
    # And the engine was invoked at the SUPERSET, not the user's params.
    assert calls["limits"] == [200]
    assert calls["min_scores"] == [0.0]

    # Each response is sliced to its own params.
    assert a["limit"] == 5
    assert len(a["matches"]) == 5
    assert a["returned_count"] == 5
    # total_count is the filtered count BEFORE the limit (no min_score here).
    assert a["total_count"] == 20

    assert b["limit"] == 50  # capped to available 20 rows in matches
    assert len(b["matches"]) == 20

    # min_score=80 keeps scores >= 80: 100,95,90,85,80 -> 5 rows.
    assert c["min_score"] == 80
    assert c["total_count"] == 5
    assert all(m["score"] >= 80 for m in c["matches"])
    # First match is the highest score (already sorted desc in the snapshot).
    assert c["matches"][0]["symbol"] == "S00"


def test_min_score_slice_is_faithful_to_engine_semantics(monkeypatch):
    _install_counting_engine(monkeypatch)
    r = client.get(
        "/v1/screen/HKEX", params={"limit": 3, "min_score": 90}
    ).json()
    # scores >= 90: 100, 95, 90 -> 3 rows; limit 3 returns all 3.
    assert r["total_count"] == 3
    assert r["returned_count"] == 3
    assert [m["score"] for m in r["matches"]] == [100.0, 95.0, 90.0]
