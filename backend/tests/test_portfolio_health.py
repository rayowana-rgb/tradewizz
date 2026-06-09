"""Unit tests for Portfolio Health + Position Quality (Elite).

Fake positions provider (simulated holdings) + fake score provider so the
aggregation logic is tested without the engine or network.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.models import Market, ScreenerCategory, ScreenerMatch
from app.portfolio_health.service import PortfolioHealthService


@dataclass
class _Pos:
    symbol: str
    market: Market
    quantity: float
    market_value: float


def _match(symbol, score, change, value, signal="BUY", cats=None):
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


def _scores():
    table = {
        "BBCA": _match("BBCA", 91, 2.0, 3e9, cats=[ScreenerCategory.bullish]),
        "NVDA": _match("NVDA", 94, 4.0, 6e9, cats=[ScreenerCategory.bullish]),
        "TPIA": _match("TPIA", 50, -3.0, 5e8, signal="SELL"),
    }

    def provider(symbol, market):
        return table.get(symbol.upper())

    return provider


def _svc(positions):
    return PortfolioHealthService(
        positions_provider=lambda uid: positions,
        score_provider=_scores(),
    )


def test_position_quality_per_holding():
    positions = [
        _Pos("BBCA", Market.IDX, 100, 100_000),
        _Pos("NVDA", Market.US, 10, 50_000),
        _Pos("TPIA", Market.IDX, 200, 20_000),
    ]
    resp = _svc(positions).position_quality(1)
    by = {p.symbol: p for p in resp.positions}
    assert by["NVDA"].quality_score >= 80  # strong leader
    assert by["BBCA"].quality_score >= 75
    assert by["TPIA"].quality_score < by["BBCA"].quality_score  # weak/SELL
    assert resp.simulated is True
    # Components present.
    for p in resp.positions:
        assert 0 <= p.trend <= 100
        assert 0 <= p.relative_strength <= 100
        assert 0 <= p.risk <= 100


def test_portfolio_health_score_and_components():
    positions = [
        _Pos("BBCA", Market.IDX, 100, 100_000),
        _Pos("NVDA", Market.US, 10, 80_000),
        _Pos("TPIA", Market.IDX, 200, 20_000),
    ]
    health = _svc(positions).health(7)
    assert 0 <= health.health_score <= 100
    assert health.rating in ("Excellent", "Good", "Fair", "Poor")
    c = health.components
    for field in (c.diversification, c.concentration_risk, c.liquidity,
                  c.quality, c.sector_exposure):
        assert 0 <= field <= 100
    assert health.simulated is True
    # Market exposure adds up to ~100%.
    assert abs(sum(health.market_exposure.values()) - 100.0) < 1.0


def test_concentration_warning_when_single_position_dominates():
    positions = [
        _Pos("NVDA", Market.US, 100, 900_000),  # 90% of equity
        _Pos("BBCA", Market.IDX, 10, 100_000),
    ]
    health = _svc(positions).health(7)
    assert any("concentration too high" in w.lower()
               for w in health.warnings)


def test_exit_warning_for_weak_position():
    positions = [
        _Pos("TPIA", Market.IDX, 200, 100_000),  # SELL signal, score 50
        _Pos("NVDA", Market.US, 10, 100_000),
    ]
    health = _svc(positions).health(7)
    assert any("TPIA" in e for e in health.exit_warnings)


def test_strength_called_out_for_strong_position():
    positions = [
        _Pos("NVDA", Market.US, 10, 50_000),
        _Pos("BBCA", Market.IDX, 100, 50_000),
        _Pos("TPIA", Market.IDX, 50, 50_000),
    ]
    health = _svc(positions).health(7)
    assert any("NVDA" in s or "BBCA" in s for s in health.strengths)


def test_empty_portfolio_is_handled():
    health = _svc([]).health(7)
    assert health.health_score >= 0
    assert any("no simulated holdings" in w.lower() for w in health.warnings)
    assert health.positions == []


def test_missing_score_treated_as_neutral():
    # A symbol with no score row -> neutral 50 quality, no crash.
    positions = [_Pos("ZZZZ", Market.US, 1, 1000)]
    resp = _svc(positions).position_quality(7)
    assert resp.positions[0].quality_score == 50.0
    assert resp.positions[0].rating == "Unknown"
