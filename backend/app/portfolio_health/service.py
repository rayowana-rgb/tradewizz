"""Portfolio Health + Position Quality service (Elite).

Aggregates the user's SIMULATED positions plus per-symbol scoring (from the
existing engine) into a 0-100 health score, per-position quality scores, and
plain-language warnings / exit signals.

Design:
  * positions_provider(user_id) -> List[SimulatedPosition]   (simulation store)
  * score_provider(symbol, market) -> ScreenerMatch|None     (existing engine)

We derive quality sub-scores (trend / relative strength / momentum / volume /
risk) from the existing screener match (score, change_percent, value_traded,
signal, categories). No new indicators are computed here.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional

from ..models import Market, ScreenerCategory, ScreenerMatch
from .models import (
    HealthComponents,
    PortfolioHealth,
    PositionQuality,
    PositionQualityResponse,
)

PositionsProvider = Callable[[int], List]
ScoreProvider = Callable[[str, Market], Optional[ScreenerMatch]]

# Concentration: a single position above this share of equity is flagged.
CONCENTRATION_WARN = 0.35  # 35%
# A position whose quality drops below this is an exit-warning candidate.
EXIT_QUALITY_FLOOR = 55.0


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _clamp(v: float, lo: float = 0.0, hi: float = 100.0) -> float:
    return max(lo, min(hi, v))


class PortfolioHealthService:
    def __init__(
        self,
        positions_provider: PositionsProvider,
        score_provider: ScoreProvider,
    ):
        self._positions = positions_provider
        self._score = score_provider

    # -- per-position quality (Phase 6) ----------------------------------
    def _quality_for(self, symbol: str, market: Market, quantity: float
                     ) -> PositionQuality:
        match: Optional[ScreenerMatch] = None
        try:
            match = self._score(symbol, market)
        except Exception:  # noqa: BLE001 - one bad symbol can't break health
            match = None

        if match is None:
            return PositionQuality(
                symbol=symbol.upper(),
                market=market,
                quantity=quantity,
                quality_score=50.0,
                trend=50.0,
                relative_strength=50.0,
                momentum=50.0,
                volume=50.0,
                risk=50.0,
                rating="Unknown",
                note="No live score available; treated as neutral.",
                low_confidence=True,
            )

        score = match.score
        chg = match.change_percent
        # Trend: anchored on the engine score (multi-factor).
        trend = score
        # Relative strength / momentum: short-term change, mapped to 0..100.
        # ASYMMETRIC by design: a green day still lifts these at the original
        # slope (so strong up-movers are recognized), but a red day is damped
        # and FLOORED at 25. A single hard down day (a -10% selloff) must NOT
        # zero these out and drag a strong, high-score name's quality below 60
        # -- that previously made the Rebalancing AI recommend trimming winners
        # right after a dip.
        rs = _clamp(50.0 + (chg * 5.0 if chg >= 0 else max(-25.0, chg * 2.0)))
        momentum = _clamp(
            50.0 + (chg * 6.0 if chg >= 0 else max(-25.0, chg * 2.4))
        )
        # Volume / liquidity: log-ish bucket of value_traded.
        volume = _liquidity_score(match.value_traded)
        # Risk (higher = safer): blends score with liquidity, penalizes SELL.
        risk = _clamp(0.6 * score + 0.4 * volume)
        if (match.signal or "").upper() == "SELL":
            risk = _clamp(risk - 25.0)

        quality = _clamp(
            0.40 * trend
            + 0.20 * rs
            + 0.15 * momentum
            + 0.10 * volume
            + 0.15 * risk
        )
        return PositionQuality(
            symbol=match.symbol,
            market=market,
            quantity=quantity,
            quality_score=round(quality, 1),
            trend=round(trend, 1),
            relative_strength=round(rs, 1),
            momentum=round(momentum, 1),
            volume=round(volume, 1),
            risk=round(risk, 1),
            rating=_quality_rating(quality),
            note=_quality_note(match, quality),
        )

    def position_quality(self, user_id: int) -> PositionQualityResponse:
        positions = self._positions(user_id)
        out = [
            self._quality_for(p.symbol, p.market, p.quantity)
            for p in positions
        ]
        return PositionQualityResponse(
            user_id=user_id,
            generated_at=_now_iso(),
            positions=out,
        )

    # -- portfolio health (Phase 5) --------------------------------------
    def health(self, user_id: int) -> PortfolioHealth:
        positions = self._positions(user_id)
        qualities = [
            self._quality_for(p.symbol, p.market, p.quantity)
            for p in positions
        ]
        # Position weights by market value.
        values = [max(0.0, p.market_value) for p in positions]
        total = sum(values)
        weights = [(v / total if total > 0 else 0.0) for v in values]

        # Market/sector exposure (% of equity).
        exposure: Dict[str, float] = {}
        for p, w in zip(positions, weights):
            exposure[p.market.value] = exposure.get(p.market.value, 0.0) + w * 100.0
        exposure = {k: round(v, 1) for k, v in exposure.items()}

        components = self._components(positions, qualities, weights)
        health_score = round(
            0.25 * components.diversification
            + 0.25 * components.concentration_risk
            + 0.15 * components.liquidity
            + 0.25 * components.quality
            + 0.10 * components.sector_exposure,
            1,
        )

        warnings, strengths, exits = self._signals(
            positions, qualities, weights, exposure
        )

        return PortfolioHealth(
            user_id=user_id,
            generated_at=_now_iso(),
            health_score=health_score,
            rating=_health_rating(health_score),
            components=components,
            warnings=warnings,
            strengths=strengths,
            exit_warnings=exits,
            market_exposure=exposure,
            positions=qualities,
            simulated=True,
        )

    # -- component math --------------------------------------------------
    def _components(
        self, positions, qualities, weights
    ) -> HealthComponents:
        n = len(positions)
        if n == 0:
            # Empty portfolio: neutral-ish, the warning text covers it.
            return HealthComponents(
                diversification=0.0,
                concentration_risk=50.0,
                liquidity=50.0,
                quality=50.0,
                sector_exposure=50.0,
            )

        # Diversification: more holdings -> higher, saturating at ~10 names.
        diversification = _clamp(min(n, 10) / 10.0 * 100.0)

        # Concentration risk (healthier when no single name dominates):
        # use Herfindahl index of weights; HHI=1 (one name) -> 0, even -> ~100.
        hhi = sum(w * w for w in weights) if weights else 1.0
        concentration_risk = _clamp((1.0 - hhi) / (1.0 - 1.0 / n) * 100.0
                                    if n > 1 else 0.0)

        # Liquidity: weighted average of per-position volume sub-score.
        liquidity = _clamp(
            sum(q.volume * w for q, w in zip(qualities, weights))
            if total_weight(weights) else
            (sum(q.volume for q in qualities) / n)
        )

        # Quality: weighted average position quality.
        quality = _clamp(
            sum(q.quality_score * w for q, w in zip(qualities, weights))
            if total_weight(weights) else
            (sum(q.quality_score for q in qualities) / n)
        )

        # Sector/market exposure balance: penalize over-concentration in one
        # market (uses market HHI).
        market_w: Dict[str, float] = {}
        for p, w in zip(positions, weights):
            market_w[p.market.value] = market_w.get(p.market.value, 0.0) + w
        m_hhi = sum(v * v for v in market_w.values()) if market_w else 1.0
        sector_exposure = _clamp((1.0 - m_hhi) * 100.0 + 30.0)

        return HealthComponents(
            diversification=round(diversification, 1),
            concentration_risk=round(concentration_risk, 1),
            liquidity=round(liquidity, 1),
            quality=round(quality, 1),
            sector_exposure=round(sector_exposure, 1),
        )

    def _signals(self, positions, qualities, weights, exposure):
        warnings: List[str] = []
        strengths: List[str] = []
        exits: List[str] = []

        if not positions:
            warnings.append(
                "No simulated holdings yet — buy a few names to build a "
                "portfolio and unlock a meaningful health score."
            )
            return warnings, strengths, exits

        # Concentration by single position.
        for p, w in zip(positions, weights):
            if w >= CONCENTRATION_WARN:
                warnings.append(
                    f"Position concentration too high in {p.symbol} "
                    f"({w * 100:.0f}% of the portfolio)."
                )

        # Concentration by market.
        for market, pct in exposure.items():
            if pct >= 60.0:
                warnings.append(
                    f"Heavy exposure to {market} ({pct:.0f}% of equity); "
                    "consider diversifying across markets."
                )

        # Per-position momentum / quality signals.
        for q in qualities:
            if q.quality_score < EXIT_QUALITY_FLOOR:
                exits.append(
                    f"{q.symbol} quality weakening "
                    f"({q.quality_score:.0f}/100) — review or trim."
                )
            elif q.momentum < 45.0:
                warnings.append(f"{q.symbol} momentum weakening.")
            elif q.quality_score >= 80.0:
                strengths.append(f"{q.symbol} remains strong "
                                 f"({q.quality_score:.0f}/100).")

        if len(positions) < 3:
            warnings.append(
                "Low diversification — fewer than 3 holdings increases "
                "single-name risk."
            )
        return warnings, strengths, exits


# --- pure helpers -----------------------------------------------------------
def total_weight(weights: List[float]) -> bool:
    return sum(weights) > 0


def _liquidity_score(value_traded: float) -> float:
    """Map turnover to a 0..100 liquidity sub-score (log-ish buckets)."""
    v = value_traded or 0.0
    if v <= 0:
        return 20.0
    import math

    # ~1e6 -> 40, ~1e8 -> 70, ~1e10 -> 100.
    score = 10.0 * (math.log10(v) - 4.0)
    return _clamp(20.0 + score * 8.0)


def _quality_rating(q: float) -> str:
    if q >= 80:
        return "Strong"
    if q >= 60:
        return "Solid"
    return "Weak"


def _quality_note(match: ScreenerMatch, quality: float) -> str:
    sig = (match.signal or "HOLD").upper()
    if sig == "SELL":
        return "Engine signal is SELL — consider trimming."
    if quality >= 85:
        return "Leadership-quality holding."
    if quality < EXIT_QUALITY_FLOOR:
        return "Below quality floor — monitor for an exit."
    if ScreenerCategory.bullish in match.categories:
        return "Constructive trend."
    return "Neutral hold."


def _health_rating(score: float) -> str:
    if score >= 85:
        return "Excellent"
    if score >= 70:
        return "Good"
    if score >= 50:
        return "Fair"
    return "Poor"
