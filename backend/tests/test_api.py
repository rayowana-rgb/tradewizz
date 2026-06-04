"""Contract tests: responses must match the Flutter app's expected JSON shape.

The API engine is swapped for one whose fetcher always fails, so these tests
exercise the deterministic mock-fallback path with no network (fast + stable).
"""

import tempfile
from pathlib import Path

from fastapi.testclient import TestClient

from app import main
from app.engine import AnalysisEngine
from app.universe import UniverseRepository


def _offline_fetch(ticker, period, interval):
    raise ConnectionError("no network in tests")


# Small controlled universe per market so contract tests stay fast and stable
# (independent of the large shipped Excel universes). Symbols are bare SYM** so
# the "not generic IDX0* mock" check still holds.
_UNIV_DIR = Path(tempfile.mkdtemp(prefix="tw_api_univ_"))
for _stem in ("idx", "hkex", "kospi", "kosdaq"):
    (_UNIV_DIR / f"{_stem}.csv").write_text(
        "symbol,name\n" + "".join(f"SYM{i:02d},Co {i}\n" for i in range(8))
    )

# Force mock fallback (offline fetcher) over a controlled universe.
main.engine = AnalysisEngine(
    fetcher=_offline_fetch,
    universe=UniverseRepository(universe_dir=_UNIV_DIR),
)

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


def test_screen_limit_param():
    r = client.get("/v1/screen/HKEX", params={"limit": 2})
    assert r.status_code == 200
    assert len(r.json()["matches"]) <= 2


def test_screen_populates_universe_even_when_fetches_fail():
    # Engine fetcher always fails, but the universe + per-symbol mock fallback
    # means /screen still returns 200 with populated matches.
    r = client.get("/v1/screen/IDX", params={"limit": 50})
    assert r.status_code == 200
    b = r.json()
    assert len(b["matches"]) > 0
    # Real universe symbols (bare IDX tickers), not generic IDX01/.. mock rows.
    symbols = {m["symbol"] for m in b["matches"]}
    assert not any(s.startswith("IDX0") for s in symbols)
    # returned_count == matches; total_count is the full (pre-limit) universe.
    assert b["returned_count"] == len(b["matches"])
    assert b["total_count"] >= b["returned_count"]


def test_screen_response_includes_pagination_metadata():
    r = client.get(
        "/v1/screen/HKEX",
        params={"limit": 3, "min_score": 0, "categories": "bullish"},
    )
    assert r.status_code == 200
    b = r.json()
    for key in ("total_count", "returned_count", "limit", "min_score",
                "categories"):
        assert key in b
    assert b["returned_count"] == len(b["matches"])
    assert b["total_count"] >= b["returned_count"]
    assert b["limit"] == 3
    assert b["categories"] == ["bullish"]


def test_screen_limit_out_of_bounds_422():
    assert client.get("/v1/screen/IDX", params={"limit": 0}).status_code == 422
    assert client.get("/v1/screen/IDX", params={"limit": 201}).status_code == 422


def test_screen_min_score_filters():
    r = client.get("/v1/screen/IDX", params={"min_score": 80})
    assert r.status_code == 200
    assert all(m["score"] >= 80 for m in r.json()["matches"])


def test_screen_sorted_by_score_then_change():
    matches = client.get("/v1/screen/HKEX").json()["matches"]
    pairs = [(m["score"], m["change_percent"]) for m in matches]
    assert pairs == sorted(pairs, reverse=True)


def test_screen_categories_filter():
    r = client.get("/v1/screen/IDX", params={"categories": "bearish"})
    assert r.status_code == 200
    for m in r.json()["matches"]:
        assert "bearish" in m["categories"]


def test_screen_unknown_category_ignored():
    # Unknown category names are dropped; request still succeeds.
    r = client.get("/v1/screen/IDX", params={"categories": "not_a_real_cat"})
    assert r.status_code == 200


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
