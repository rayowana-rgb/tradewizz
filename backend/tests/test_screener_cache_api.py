"""API-level tests for the market-close screener cache on /v1/screen/{market}.

Uses the test hook ``main.set_screener_now_override`` to pin the market clock
to OPEN or CLOSED deterministically, so behavior does not depend on wall time.
"""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from app import main
from app.models import Market

client = TestClient(main.app)

HK = ZoneInfo("Asia/Hong_Kong")
OPEN_TIME = datetime(2026, 6, 8, 11, 0, tzinfo=HK)   # Mon 11:00 HKT -> OPEN
CLOSED_TIME = datetime(2026, 6, 8, 18, 0, tzinfo=HK)  # Mon 18:00 HKT -> CLOSED


@pytest.fixture(autouse=True)
def _reset_now_hook():
    # Snapshot freshness is decided by the latest cached candle's TRADING DATE
    # vs. the snapshot's market_date. The default probe reads the GLOBAL cache
    # registry, which other test modules prime with candles dated "today";
    # those would map to a trading date newer than the pinned CLOSED_TIME
    # (2026-06-08) and spuriously invalidate the snapshot. Clear the registry
    # before each test so the probe is indeterminate (-> keep snapshot),
    # isolating these API tests from cross-module cache pollution.
    try:
        from app.cache import all_caches

        for _c in all_caches():
            try:
                _c.clear()
            except Exception:  # noqa: BLE001 - best-effort isolation
                pass
    except Exception:  # noqa: BLE001
        pass
    yield
    main.set_screener_now_override(None)


def _pin(now: datetime) -> None:
    main.set_screener_now_override(lambda _m: now)


def test_response_includes_cache_metadata_when_closed():
    _pin(CLOSED_TIME)
    r = client.get("/v1/screen/KOSPI", params={"limit": 5})
    assert r.status_code == 200
    b = r.json()
    for key in (
        "cached",
        "generated_at",
        "market_date",
        "market_status",
        "next_refresh_rule",
    ):
        assert key in b
    assert b["market_status"] == "CLOSED"
    assert b["market_date"] == "2026-06-08"
    assert b["next_refresh_rule"] == "Will refresh after next market close"
    # First close-time call runs + saves -> not yet cached.
    assert b["cached"] is False
    assert len(b["matches"]) > 0


def test_closed_then_reopen_same_day_is_cached_no_rerun():
    _pin(CLOSED_TIME)
    first = client.get("/v1/screen/KOSDAQ", params={"limit": 4}).json()
    assert first["cached"] is False
    gen1 = first["generated_at"]

    # Reopen app same day -> served from cache, same generated_at.
    second = client.get("/v1/screen/KOSDAQ", params={"limit": 4}).json()
    assert second["cached"] is True
    assert second["generated_at"] == gen1
    assert [m["symbol"] for m in second["matches"]] == [
        m["symbol"] for m in first["matches"]
    ]


def test_open_serves_cached_and_does_not_rescreen():
    # Seed a market-close snapshot.
    _pin(CLOSED_TIME)
    seed = client.get("/v1/screen/HKEX", params={"limit": 6}).json()
    gen = seed["generated_at"]

    # Market opens -> cached snapshot reused (same generated_at), flagged OPEN.
    _pin(OPEN_TIME)
    opened = client.get("/v1/screen/HKEX", params={"limit": 6}).json()
    assert opened["cached"] is True
    assert opened["market_status"] == "OPEN"
    assert opened["generated_at"] == gen
    assert opened["warning"] == "Using latest market-close screening result"


def test_force_refresh_denied_when_open():
    # Seed snapshot while closed.
    _pin(CLOSED_TIME)
    client.get("/v1/screen/IDX", params={"limit": 7}).json()

    _pin(OPEN_TIME)
    r = client.get(
        "/v1/screen/IDX", params={"limit": 7, "force_refresh": True}
    ).json()
    assert r["cached"] is True
    assert r["warning"] == "Screening refresh is only allowed after market close."


def test_force_refresh_allowed_when_closed():
    _pin(CLOSED_TIME)
    first = client.get("/v1/screen/IDX", params={"limit": 8}).json()
    gen1 = first["generated_at"]

    forced = client.get(
        "/v1/screen/IDX", params={"limit": 8, "force_refresh": True}
    ).json()
    assert forced["cached"] is False
    # A fresh run produces a new generated_at (>= the first).
    assert forced["generated_at"] >= gen1
