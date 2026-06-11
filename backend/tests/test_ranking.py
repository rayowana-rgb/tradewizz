"""Screener ranking fixes: liquidity tiebreaker + liquidity filter.

See docs/screener-ranking-audit.md. These verify Fix A (sort tiebreaker) and
Fix B (min_value_traded floor) without touching score/signal/category logic.
"""

import numpy as np
import pandas as pd

from app.engine import (
    AnalysisEngine,
    DEFAULT_MIN_VALUE_TRADED_IDR,
    default_min_value_traded,
)
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult


def _match(symbol, score, value_traded, change=0.0, cats=None):
    return ScreenerMatch(
        symbol=symbol,
        name=symbol,
        score=score,
        signal="BUY",
        price=100.0,
        change_percent=change,
        categories=cats or [ScreenerCategory.bullish],
        value_traded=value_traded,
    )


def _result(matches):
    return ScreenerResult(
        market=Market.IDX, matches=matches, generated_at="2026-06-05T00:00:00Z"
    )


# --- Fix A: liquidity tiebreaker --------------------------------------------

def test_higher_value_traded_wins_when_score_identical():
    # Three names all at score 86; should rank by value_traded desc.
    matches = [
        _match("LOWLIQ", 86.0, 50_000_000, change=10.0),   # tiny turnover
        _match("BIGLIQ", 86.0, 3_000_000_000_000),         # 3T turnover
        _match("MIDLIQ", 86.0, 5_000_000_000),             # 5B turnover
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    order = [m.symbol for m in res.matches]
    assert order == ["BIGLIQ", "MIDLIQ", "LOWLIQ"]


def test_score_still_dominates_over_liquidity():
    # A higher score outranks higher liquidity (score is primary key).
    matches = [
        _match("HISCORE", 90.0, 1_000),                    # tiny turnover
        _match("LOSCORE", 86.0, 9_000_000_000_000),        # huge turnover
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert [m.symbol for m in res.matches] == ["HISCORE", "LOSCORE"]


def test_change_percent_breaks_remaining_ties():
    # Same score AND same value_traded -> change_percent desc decides.
    matches = [
        _match("A", 86.0, 5_000_000_000, change=-3.0),
        _match("B", 86.0, 5_000_000_000, change=4.0),
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert [m.symbol for m in res.matches] == ["B", "A"]


# --- Fix B: liquidity filter ------------------------------------------------

def test_low_liquidity_is_filtered_out():
    matches = [
        _match("BIG", 86.0, 3_000_000_000),     # >= 2B floor
        _match("SHELL", 86.0, 0),               # untraded
        _match("MICRO", 86.0, 63_000_000),      # 63M, below 2B
    ]
    res = AnalysisEngine._finalize(
        _result(matches), limit=50, min_score=0, categories=None,
        min_value_traded=2_000_000_000,
    )
    symbols = {m.symbol for m in res.matches}
    assert symbols == {"BIG"}
    assert res.total_count == 1  # SHELL + MICRO excluded before pagination


def test_zero_floor_keeps_everything():
    matches = [
        _match("BIG", 86.0, 3_000_000_000),
        _match("SHELL", 86.0, 0),
    ]
    res = AnalysisEngine._finalize(_result(matches), limit=50, min_score=0,
                                   categories=None, min_value_traded=0)
    assert len(res.matches) == 2


def test_per_market_default_floor_scaling():
    assert default_min_value_traded(Market.IDX) == DEFAULT_MIN_VALUE_TRADED_IDR
    # HKEX/KOSPI/KOSDAQ scaled below the raw IDR figure.
    assert default_min_value_traded(Market.HKEX) < DEFAULT_MIN_VALUE_TRADED_IDR
    assert default_min_value_traded(Market.KOSPI) < DEFAULT_MIN_VALUE_TRADED_IDR
    assert default_min_value_traded(Market.KOSDAQ) < DEFAULT_MIN_VALUE_TRADED_IDR


# --- Global-market liquidity scaling (Explore empty-results fix) -------------

def test_default_floor_sane_for_all_global_markets():
    """Every market's default floor must be a sane LOCAL-currency magnitude.

    The bug: US/Japan/Singapore (etc.) fell through to the raw 2B *IDR* figure,
    which, applied to local turnover, wiped out the entire market. Each market's
    floor should equal 2B IDR / idr_per_unit(market).
    """
    base = DEFAULT_MIN_VALUE_TRADED_IDR
    # IDX is the only market that keeps the raw IDR figure (idr_per_unit == 1).
    assert default_min_value_traded(Market.IDX) == base
    # US: 2e9 / 16000 ~= 125k USD (NOT 2 billion USD).
    assert default_min_value_traded(Market.US) == base / 16000.0
    assert default_min_value_traded(Market.US) < 1_000_000  # << 2B USD
    # Japan: 2e9 / 105 ~= 19M JPY.
    assert default_min_value_traded(Market.JAPAN) == base / 105.0
    # Singapore: 2e9 / 12000 ~= 167k SGD.
    assert default_min_value_traded(Market.SINGAPORE) == base / 12000.0
    assert default_min_value_traded(Market.SINGAPORE) < 1_000_000  # << 2B SGD
    # India / Vietnam also scaled (not raw IDR-against-local-currency).
    assert default_min_value_traded(Market.INDIA) == base / 190.0
    assert default_min_value_traded(Market.VIETNAM) == base / 0.65
    # Legacy markets unchanged.
    assert default_min_value_traded(Market.HKEX) == base / 2000.0
    assert default_min_value_traded(Market.KOSPI) == base / 12.0
    assert default_min_value_traded(Market.KOSDAQ) == base / 12.0


def test_value_floor_scales_legacy_idr_thresholds_across_markets():
    """_value_floor must divide the legacy IDR floor by idr_per_unit(market)."""
    for idr in (500_000_000.0, 5_000_000_000.0, 10_000_000_000.0):
        # IDX keeps the raw IDR amount.
        assert AnalysisEngine._value_floor(Market.IDX, idr) == idr
        # Legacy scaling preserved exactly.
        assert AnalysisEngine._value_floor(Market.HKEX, idr) == idr / 2000.0
        assert AnalysisEngine._value_floor(Market.KOSPI, idr) == idr / 12.0
        assert AnalysisEngine._value_floor(Market.KOSDAQ, idr) == idr / 12.0
        # New markets scaled by the shared FX table.
        assert AnalysisEngine._value_floor(Market.US, idr) == idr / 16000.0
        assert AnalysisEngine._value_floor(Market.JAPAN, idr) == idr / 105.0
        assert AnalysisEngine._value_floor(Market.SINGAPORE, idr) == idr / 12000.0
        assert AnalysisEngine._value_floor(Market.INDIA, idr) == idr / 190.0
        assert AnalysisEngine._value_floor(Market.VIETNAM, idr) == idr / 0.65
        # None market -> legacy IDR (unchanged).
        assert AnalysisEngine._value_floor(None, idr) == idr


def test_cheap_price_uses_shared_scaling_for_new_markets():
    """Legacy ceilings preserved; new markets derive from the FX table."""
    # Legacy hand-tuned ceilings unchanged.
    assert AnalysisEngine._cheap_price(Market.IDX) == 300.0
    assert AnalysisEngine._cheap_price(Market.HKEX) == 5.0
    assert AnalysisEngine._cheap_price(Market.KOSPI) == 5000.0
    assert AnalysisEngine._cheap_price(Market.KOSDAQ) == 5000.0
    # New markets: 300 IDR base / idr_per_unit -> sane local magnitude.
    assert AnalysisEngine._cheap_price(Market.US) == 300.0 / 16000.0
    assert AnalysisEngine._cheap_price(Market.JAPAN) == 300.0 / 105.0
    assert AnalysisEngine._cheap_price(Market.SINGAPORE) == 300.0 / 12000.0


# --- engine.screen integration ----------------------------------------------

def _universe_engine(tmp_path):
    (tmp_path / "idx.csv").write_text(
        "symbol,name\nAAA,Co A\nBBB,Co B\nCCC,Co C\n"
    )
    from app.universe import UniverseRepository

    # Per-symbol synthetic data with differing turnover via volume.
    def fetch(ticker, period, interval):
        base = {"AAA.JK": 1_000.0, "BBB.JK": 9_000.0, "CCC.JK": 50.0}
        vol = base.get(ticker, 1_000.0)
        n = 300
        close = 100 + np.arange(n) * 1.0  # uptrend -> same score for all
        return pd.DataFrame({
            "Open": close, "High": close + 1, "Low": close - 1,
            "Close": close, "Volume": np.full(n, vol),
        })

    return AnalysisEngine(
        fetcher=fetch, universe=UniverseRepository(universe_dir=tmp_path)
    )


def test_screen_orders_by_liquidity_when_scores_tie(tmp_path):
    eng = _universe_engine(tmp_path)
    res = eng.screen(Market.IDX, min_value_traded=0)
    # All three share the uptrend score; order must follow value_traded desc.
    assert [m.symbol for m in res.matches] == ["BBB", "AAA", "CCC"]
    assert res.matches[0].value_traded > res.matches[-1].value_traded


def test_screen_filters_below_threshold(tmp_path):
    eng = _universe_engine(tmp_path)
    # close ~ 399 at the last bar; CCC volume 50 -> ~20k turnover (filtered);
    # AAA vol 1000 -> ~399k; BBB vol 9000 -> ~3.6M. Floor at 1M keeps only BBB.
    res = eng.screen(Market.IDX, min_value_traded=1_000_000)
    assert [m.symbol for m in res.matches] == ["BBB"]


# --- regression: score/signal/contract unchanged ----------------------------

def test_multifactor_score_is_deterministic_and_bounded():
    # Multi-factor scoring: a perfectly-linear ramp with no market context is
    # NOT an elite setup (overbought RSI, no relative-strength/regime
    # confirmation, flat participation) -> a mid-band, deterministic score.
    eng = AnalysisEngine()
    n = 300
    close = 100 + np.arange(n) * 1.0
    df = pd.DataFrame({
        "Open": close, "High": close + 1, "Low": close - 1, "Close": close,
        # Liquid volume so the Phase F liquidity cap does not apply here; this
        # test pins the multi-factor composite, not the liquidity floor.
        "Volume": np.full(n, 50_000_000.0),
    })
    from app import indicators
    ind = indicators.compute_all(df)
    cats = eng.categorize(ind, Market.IDX)
    signal, score = eng._signal_and_score(ind, cats)
    # Deterministic and on the 0..100 scale; trend is strong but confluence is
    # incomplete -> HOLD band (not BUY) without RS/regime context.
    assert 0.0 <= score <= 100.0
    assert signal in ("HOLD", "BUY")
    # Phase 11B liquidity-first: a strong-trend, highly-liquid name scores
    # higher than under the old technical-heavy weights.
    assert score == 72.4  # stable composite for this (liquid) fixture
    # Re-running yields the identical score (pure function, no randomness).
    assert eng._signal_and_score(ind, cats)[1] == score


def test_screenermatch_contract_has_value_traded_default():
    # value_traded is additive with a default -> old payloads still validate.
    m = ScreenerMatch(
        symbol="X", score=86.0, price=100.0, change_percent=1.0,
    )
    assert m.value_traded == 0.0  # default, backward-compatible
    # And the previously-required fields are intact.
    assert m.symbol == "X" and m.signal == "HOLD"


# --- Global market screening is not wiped by the default liquidity floor -----

def _global_engine(tmp_path, market, suffix):
    """Universe engine for an arbitrary market, asserting tickers carry the
    market's yfinance suffix (and never .JK for non-IDX markets)."""
    stem = market.value.lower()
    tmp_path.mkdir(parents=True, exist_ok=True)
    # HKEX universe loading keeps only numeric equity codes (1..9999), so use
    # numeric symbols there; alphabetic tickers are fine for the other markets.
    if market is Market.HKEX:
        rows = "symbol,name\n0700,Co A\n0005,Co B\n"
    else:
        rows = "symbol,name\nAAA,Co A\nBBB,Co B\n"
    (tmp_path / f"{stem}.csv").write_text(rows)
    from app.universe import UniverseRepository

    seen_tickers = []

    def fetch(ticker, period, interval):
        seen_tickers.append(ticker)
        # Local-currency prices/volumes that yield turnover comfortably above
        # the scaled default floor for the market (but far below 2B local).
        n = 300
        close = 50 + np.arange(n) * 0.5  # gentle uptrend
        vol = np.full(n, 5_000_000.0)
        return pd.DataFrame({
            "Open": close, "High": close + 1, "Low": close - 1,
            "Close": close, "Volume": vol,
        })

    eng = AnalysisEngine(
        fetcher=fetch, universe=UniverseRepository(universe_dir=tmp_path)
    )
    return eng, seen_tickers


def test_non_idx_screen_not_wiped_by_default_floor(tmp_path):
    """Regression: selecting a non-Indonesia market returns matches.

    Before the fix the default floor was 2B in *local* currency for US/JP/SG,
    so every match was filtered out. With FX scaling the default floor is sane
    and the market screens normally.
    """
    for market in (Market.US, Market.JAPAN, Market.SINGAPORE):
        eng, _ = _global_engine(tmp_path / market.value, market, None)
        floor = default_min_value_traded(market)
        res = eng.screen(market, min_value_traded=floor)
        assert res.matches, f"{market.value} wiped out by liquidity floor"
        assert res.market == market


def test_non_idx_tickers_have_no_jk_suffix(tmp_path):
    """No .JK is appended to non-IDX tickers; US stays bare, JP gets .T, etc."""
    cases = [
        (Market.US, ""),
        (Market.JAPAN, ".T"),
        (Market.SINGAPORE, ".SI"),
        (Market.HKEX, ".HK"),
    ]
    for market, suffix in cases:
        eng, seen = _global_engine(tmp_path / f"jk_{market.value}", market, suffix)
        eng.screen(market, min_value_traded=0)
        assert seen, f"no tickers fetched for {market.value}"
        # No ticker may ever carry a .JK suffix for a non-IDX market.
        for t in seen:
            assert not t.endswith(".JK"), f"{t} wrongly suffixed .JK"
        # The equity universe tickers (AAA/BBB) must carry the market suffix
        # (or be bare for US). Index context tickers (e.g. ^N225) are excluded.
        equity = [t for t in seen if not t.startswith("^")]
        assert equity, f"no equity tickers fetched for {market.value}"
        for t in equity:
            if suffix:
                assert t.endswith(suffix), f"{t} missing {suffix}"
            else:
                assert "." not in t, f"US ticker {t} should be bare"
