"""Contract tests: responses must match the Flutter app's expected JSON shape.

The API engine is swapped for one whose fetcher always fails, so these tests
exercise the deterministic mock-fallback path with no network (fast + stable).
"""

from fastapi.testclient import TestClient

from app import main
from app.engine import AnalysisEngine


def _offline_fetch(ticker, period, interval):
    raise ConnectionError("no network in tests")


# Force mock fallback for the whole API test module.
main.engine = AnalysisEngine(fetcher=_offline_fetch)

client = TestClient(main.app)

CATEGORY_WIRE_NAMES = {
    "bullish",
    "bearish",
    "scalping",
    "accumulation",
    "pullback",
    "accumulation_silent",
    "turnaround_multibagger",
    "frequently_traded",
    "short_candidate",
    "ara_hunter",
}


def test_health():
    r = client.get("/v1/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["service"] == "tradewiz-backend"
    assert "version" in body


def test_analyze_shape():
    r = client.get("/v1/analyze/BBCA", params={"market": "IDX"})
    assert r.status_code == 200
    b = r.json()
    assert b["symbol"] == "BBCA"
    assert b["market"] == "IDX"
    assert b["signal"] in {"BUY", "HOLD", "SELL"}
    assert 0 <= b["score"] <= 100
    assert isinstance(b["highlights"], list)
    assert "generated_at" in b


def test_analyze_is_deterministic():
    a = client.get("/v1/analyze/TLKM", params={"market": "IDX"}).json()
    b = client.get("/v1/analyze/TLKM", params={"market": "IDX"}).json()
    assert a["signal"] == b["signal"]
    assert a["score"] == b["score"]


def test_screen_shape_and_categories():
    r = client.get("/v1/screen/HKEX")
    assert r.status_code == 200
    b = r.json()
    assert b["market"] == "HKEX"
    assert len(b["matches"]) > 0
    for m in b["matches"]:
        assert {"symbol", "name", "score", "signal", "price",
                "change_percent", "categories"} <= set(m.keys())
        for c in m["categories"]:
            assert c in CATEGORY_WIRE_NAMES


def test_screen_unknown_market_404():
    r = client.get("/v1/screen/NASDAQ")
    assert r.status_code == 404


def test_predict_weekly_shape():
    r = client.get("/v1/predict_weekly/0700")
    assert r.status_code == 200
    b = r.json()
    assert b["symbol"] == "0700"
    assert b["direction"] in {"UP", "DOWN", "FLAT"}
    assert 0 <= b["confidence"] <= 1
    assert "expected_change_percent" in b
    assert "rationale" in b


def test_cors_header_present():
    r = client.get("/v1/health", headers={"Origin": "http://localhost"})
    assert r.headers.get("access-control-allow-origin") == "*"
