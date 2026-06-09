"""Unit tests for the Opportunity Radar / Daily Picks / Multibagger service.

Uses a deterministic fake screen provider (no engine, no network) so the
ranking + selection logic is tested in isolation.
"""

from __future__ import annotations

from app.cache_layer.cache_manager import CacheManager as _CacheManager
from app.models import Market, ScreenerCategory, ScreenerMatch, ScreenerResult
from app.radar.service import RadarService


def _match(symbol, score, change, value, cats=None, signal="BUY"):
    return ScreenerMatch(
        symbol=symbol,
        name=symbol,
        score=score,
        signal=signal,
        price=100.0,
        change_percent=change,
        categories=cats or [],
        value_traded=value,
    )


def _make_result(market, matches):
    return ScreenerResult(
        market=market,
        matches=list(matches),
        generated_at="2026-06-09T00:00:00Z",
    )


def _fake_provider(per_market):
    """Return a screen provider mapping Market -> list[ScreenerMatch]."""

    def provider(market, limit=50, min_score=0.0, min_value_traded=0.0):
        matches = per_market.get(market, [])
        return _make_result(market, matches[:limit])

    return provider


def _bull_us():
    # Mostly advancing (bull regime), one clear leader.
    return [
        _match("NVDA", 93, 5.0, 5e9, [ScreenerCategory.bullish]),
        _match("AAPL", 89, 2.0, 4e9, [ScreenerCategory.bullish]),
        _match("MSFT", 86, 1.0, 3e9),
        _match("TSLA", 70, 0.5, 1e9),
        _match("META", 60, 0.2, 5e8),
        _match("AMZN", 55, 0.1, 4e8),
    ]


def _idx():
    return [
        _match("BBCA", 90, 3.0, 2e9, [ScreenerCategory.bullish]),
        _match("MPMX", 92, 4.0, 1.5e9,
               [ScreenerCategory.turnaround_multibagger]),
        _match("TPIA", 63, -1.0, 8e8, signal="HOLD"),
    ]


def _svc():
    return RadarService(
        screen_provider=_fake_provider({Market.US: _bull_us(), Market.IDX: _idx()}),
        markets=[Market.US, Market.IDX],
        cache=_CacheManager(),
    )


def test_opportunities_buckets_present():
    resp = _svc().opportunities()
    assert resp.global_top10, "global pool should be non-empty"
    assert resp.us_top10
    assert resp.idx_top10
    # Global pool is ranked by composite score desc.
    scores = [o.composite_rank_score for o in resp.global_top10]
    assert scores == sorted(scores, reverse=True)


def test_opportunity_fields_populated():
    o = _svc().opportunities().global_top10[0]
    assert o.symbol
    assert o.market in (Market.US, Market.IDX)
    assert o.recommendation
    assert o.opportunity_reason
    assert o.market_regime in ("BULL", "NEUTRAL", "BEAR")


def test_daily_picks_ranked_and_numbered():
    resp = _svc().daily(count=5)
    assert resp.title == "Today's Top Opportunities"
    assert len(resp.picks) == 5
    assert [p.rank for p in resp.picks] == [1, 2, 3, 4, 5]
    # Highest composite first => top score should lead.
    assert resp.picks[0].score >= resp.picks[-1].score


def test_multibagger_filters_to_strong_bull_names():
    resp = _svc().multibagger()
    # Criteria advertised.
    assert "Bull market regime" in resp.criteria
    # All candidates satisfy score > 85 and carry conviction + risk.
    for c in resp.candidates:
        assert c.score > 85
        assert c.conviction in ("SPECULATIVE", "MODERATE", "HIGH")
        assert c.risk_level in ("LOW", "MEDIUM", "HIGH")
        assert c.market_regime == "BULL"


def test_multibagger_excludes_low_score_or_weak_rs():
    resp = _svc().multibagger()
    symbols = {c.symbol for c in resp.candidates}
    # TPIA (score 63, negative change) must never qualify.
    assert "TPIA" not in symbols


def test_one_bad_market_does_not_break_radar():
    def provider(market, limit=50, min_score=0.0, min_value_traded=0.0):
        if market == Market.US:
            raise RuntimeError("data source down")
        return _make_result(market, _idx())

    svc = RadarService(provider, markets=[Market.US, Market.IDX],
                       cache=_CacheManager())
    resp = svc.opportunities()  # must not raise
    assert resp.idx_top10  # IDX still produced
