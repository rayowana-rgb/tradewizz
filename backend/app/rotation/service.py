"""Global Rotation Engine service — rank markets by opportunity environment.

For each market we reuse the EXISTING Radar output (`market_top`, which is the
screener + ranking + regime pipeline) and derive, WITHOUT recomputing any
scoring/indicators:

  * top_score_average  — average score of the top 20 names.
  * strong_count       — names with score >= 85.
  * elite_count        — names with score >= 90.
  * regime             — bull / neutral / bear (from Radar).
  * breadth            — % of scanned names advancing (change_percent > 0).
  * liquidity          — share of names with positive turnover (0..100).
  * volatility         — dispersion of change_percent (0..100, capped).

These combine into a 0..100 rotation_score; markets are ranked and tagged
OVERWEIGHT / NEUTRAL / UNDERWEIGHT / AVOID. No LLM, no broker contact.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import List, Optional, Protocol

from ..models import Market
from ..radar.models import Opportunity
from .models import (
    GlobalRotationResponse,
    MarketRotation,
    REC_AVOID,
    REC_NEUTRAL,
    REC_OVERWEIGHT,
    REC_UNDERWEIGHT,
)

STRONG_SCORE = 85.0
ELITE_SCORE = 90.0
REGIME_BULL = "BULL"
REGIME_BEAR = "BEAR"

# Rotation score weights (sum = 1.0).
W_TOP_AVG = 0.40
W_STRONG = 0.20
W_ELITE = 0.15
W_BREADTH = 0.15
W_REGIME = 0.10


class RadarLike(Protocol):
    def market_top(self, market: Market, limit: int = 50) -> List[Opportunity]: ...


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session_date() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _regime_factor(regime: str) -> float:
    return {REGIME_BULL: 100.0, "NEUTRAL": 60.0, REGIME_BEAR: 25.0}.get(
        regime, 60.0
    )


def _recommendation(score: float, regime: str, elite: int) -> str:
    if regime == REGIME_BEAR and elite == 0:
        return REC_AVOID
    if score >= 80:
        return REC_OVERWEIGHT
    if score >= 60:
        return REC_NEUTRAL
    return REC_UNDERWEIGHT


class GlobalRotationService:
    def __init__(
        self,
        radar: RadarLike,
        markets: Optional[List[Market]] = None,
    ):
        self._radar = radar
        self._markets = markets or list(Market)

    def _market_rotation(self, market: Market) -> MarketRotation:
        top = self._radar.market_top(market, limit=50)
        if not top:
            return MarketRotation(
                market=market, rotation_score=0.0, regime="NEUTRAL",
                recommendation=REC_UNDERWEIGHT,
            )
        regime = top[0].market_regime
        top20 = top[:20]
        scores = [o.score for o in top20]
        top_avg = sum(scores) / len(scores) if scores else 0.0
        strong = sum(1 for o in top if o.score >= STRONG_SCORE)
        elite = sum(1 for o in top if o.score >= ELITE_SCORE)
        advancing = sum(1 for o in top if o.change_percent > 0)
        breadth = advancing / len(top) * 100.0 if top else 0.0
        liquid = sum(1 for o in top if o.liquidity > 0)
        liquidity = liquid / len(top) * 100.0 if top else 0.0
        volatility = _volatility([o.change_percent for o in top])

        # Normalize counts to 0..100 against a soft cap so big universes don't
        # dominate purely on raw counts. Caps are deliberately modest so a
        # handful of elite/strong names already signals a healthy environment.
        strong_n = min(100.0, strong / 12.0 * 100.0)
        elite_n = min(100.0, elite / 6.0 * 100.0)

        rotation = (
            W_TOP_AVG * top_avg
            + W_STRONG * strong_n
            + W_ELITE * elite_n
            + W_BREADTH * breadth
            + W_REGIME * _regime_factor(regime)
        )
        rotation = round(max(0.0, min(100.0, rotation)), 1)

        return MarketRotation(
            market=market,
            rotation_score=rotation,
            regime=regime,
            top_score_average=round(top_avg, 1),
            elite_count=elite,
            strong_count=strong,
            breadth=round(breadth, 1),
            liquidity=round(liquidity, 1),
            volatility=round(volatility, 1),
            recommendation=_recommendation(rotation, regime, elite),
        )

    def global_rotation(self) -> GlobalRotationResponse:
        rows: List[MarketRotation] = []
        for market in self._markets:
            try:
                rows.append(self._market_rotation(market))
            except Exception:  # noqa: BLE001 - one bad market can't break it
                continue
        rows.sort(key=lambda r: r.rotation_score, reverse=True)
        for i, r in enumerate(rows, start=1):
            r.rank = i

        best = rows[0].market.value if rows else ""
        return GlobalRotationResponse(
            generated_at=_now_iso(),
            session_date=_session_date(),
            best_market=best,
            rotation_summary=_summary(rows),
            markets=rows,
            simulated=True,
        )


# --- pure helpers -----------------------------------------------------------
def _volatility(changes: List[float]) -> float:
    if not changes:
        return 0.0
    n = len(changes)
    mean = sum(changes) / n
    var = sum((c - mean) ** 2 for c in changes) / n
    std = var ** 0.5
    # Map a ~5% std-dev to ~100; cap.
    return min(100.0, std / 5.0 * 100.0)


def _summary(rows: List[MarketRotation]) -> str:
    if not rows:
        return "No market data available right now."
    overweight = [r.market.value for r in rows
                  if r.recommendation == REC_OVERWEIGHT]
    if len(overweight) >= 2:
        return (
            f"{overweight[0]} and {overweight[1]} show the strongest "
            "opportunity breadth today."
        )
    if overweight:
        return f"{overweight[0]} shows the strongest opportunity breadth today."
    top = rows[0]
    return (
        f"{top.market.value} leads today, but no market is clearly "
        "overweight — stay selective."
    )
