"""Radar service: re-rank existing screener output into opportunities.

Inputs come straight from the EXISTING engine.screen() (real scoring + real
indicators). This module does NOT compute new fundamentals/indicators; it
derives a composite *ranking* signal from the fields the screener already
returns (score, value_traded as liquidity, change_percent as a short-term
relative-strength proxy) and a per-scan market regime, then writes human
recommendations.

Ranking factors (as specified):
  * Score            - the engine's multi-factor score (primary).
  * Liquidity        - value_traded, percentile-ranked within the scan.
  * Relative Strength- change_percent, percentile-ranked within the scan.
  * Market Regime    - bull/neutral/bear from scan breadth (advancers share).
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional

from ..cache_layer import CacheManager, get_cache_manager
from ..market_session import MarketSessionState, get_market_session_state
from ..models import Market, ScreenerCategory, ScreenerResult

CACHE_NAMESPACE = "radar"
from .models import (
    DailyPick,
    DailyPicksResponse,
    MultibaggerCandidate,
    MultibaggerResponse,
    OpportunitiesResponse,
    Opportunity,
)

# A screen provider returns a ScreenerResult for a market.
ScreenProvider = Callable[..., ScreenerResult]

REGIME_BULL = "BULL"
REGIME_NEUTRAL = "NEUTRAL"
REGIME_BEAR = "BEAR"

# Multibagger thresholds (as specified): strong trend + high RS + strong
# liquidity + score > 85 + bull regime.
MULTIBAGGER_MIN_SCORE = 85.0
MULTIBAGGER_MIN_RS = 60.0          # relative-strength percentile
MULTIBAGGER_MIN_LIQUIDITY_PCT = 50.0  # liquidity percentile

# Composite ranking weights (sum = 1.0).
W_SCORE = 0.55
W_RS = 0.20
W_LIQUIDITY = 0.15
W_REGIME = 0.10


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _percentile_ranks(values: List[float]) -> List[float]:
    """Map each value to its 0..100 percentile within the list (ties share)."""
    n = len(values)
    if n == 0:
        return []
    if n == 1:
        return [100.0]
    order = sorted(range(n), key=lambda i: values[i])
    ranks = [0.0] * n
    for rank, idx in enumerate(order):
        ranks[idx] = 100.0 * rank / (n - 1)
    return ranks


def _regime_from_breadth(matches) -> str:
    """Bull/neutral/bear from advancers' share of the scan (change_percent)."""
    if not matches:
        return REGIME_NEUTRAL
    adv = sum(1 for m in matches if m.change_percent > 0)
    share = adv / len(matches)
    if share >= 0.55:
        return REGIME_BULL
    if share <= 0.40:
        return REGIME_BEAR
    return REGIME_NEUTRAL


def _regime_factor(regime: str) -> float:
    return {
        REGIME_BULL: 100.0,
        REGIME_NEUTRAL: 60.0,
        REGIME_BEAR: 25.0,
    }.get(regime, 60.0)


class RadarService:
    def __init__(
        self,
        screen_provider: ScreenProvider,
        markets: Optional[List[Market]] = None,
        cache: Optional[CacheManager] = None,
    ):
        self._screen = screen_provider
        # Markets contributing to the GLOBAL scan. Defaults to all supported.
        self._markets = markets or list(Market)
        self._cache = cache or get_cache_manager()

    def clear_cache(self) -> None:
        self._cache.invalidate(CACHE_NAMESPACE)

    # -- scan + rank -----------------------------------------------------
    def _opportunities_for(
        self, market: Market, limit: int = 50
    ) -> List[Opportunity]:
        """Screen one market and rank it into Opportunities."""
        result = self._screen(
            market=market, limit=limit, min_score=0.0, min_value_traded=0.0
        )
        # Phase H: illiquid names (value traded below the investable threshold)
        # are never opportunities — they can't be hero / radar / daily picks /
        # multibagger. They remain visible in the raw screener (with a warning)
        # but are excluded from every "best stock" selection here.
        matches = [m for m in result.matches if not getattr(m, "illiquid", False)]
        if not matches:
            return []
        regime = _regime_from_breadth(matches)
        rs_ranks = _percentile_ranks([m.change_percent for m in matches])
        liq_ranks = _percentile_ranks([m.value_traded for m in matches])
        regime_f = _regime_factor(regime)

        opps: List[Opportunity] = []
        for m, rs, liq in zip(matches, rs_ranks, liq_ranks):
            composite = (
                W_SCORE * m.score
                + W_RS * rs
                + W_LIQUIDITY * liq
                + W_REGIME * regime_f
            )
            opps.append(
                Opportunity(
                    symbol=m.symbol,
                    market=market,
                    name=m.name,
                    score=m.score,
                    signal=m.signal,
                    recommendation=_recommendation(m.signal, m.score),
                    opportunity_reason=_reason(m, rs, liq, regime),
                    relative_strength=round(rs, 1),
                    liquidity=m.value_traded,
                    change_percent=m.change_percent,
                    market_regime=regime,
                    composite_rank_score=round(composite, 2),
                )
            )
        opps.sort(key=lambda o: o.composite_rank_score, reverse=True)
        return opps

    def _safe_for(self, market: Market, limit: int = 50) -> List[Opportunity]:
        """Freshness-gated per-market scan that never raises (bad market -> []).

        Per-market results are cached under ``radar_<MARKET>_<limit>`` for the
        radar TTL (5 minutes), but served through the trading-date freshness
        policy: while the market is OPEN a too-old (>30 min) or previous-day
        entry is rebuilt rather than reused, so SCORING / RANKING never run on
        stale data (freshness rule #5). All higher-level accessors
        (``market_top``, ``_global_pool``, ``opportunities``, ``daily``,
        ``multibagger``) and Morning Brief + Global Rotation funnel through
        here, so ``engine.screen()`` runs at most once per market per fresh TTL.
        """
        key = f"{CACHE_NAMESPACE}_{market.value}_{limit}"

        def _build() -> List[Opportunity]:
            try:
                return self._opportunities_for(market, limit=limit)
            except Exception:  # noqa: BLE001
                return []

        result = self._cache.get_or_build_fresh(
            CACHE_NAMESPACE, key, _build, market
        )
        # Only fresh per-market scans feed ranking. A stale fallback (provider
        # down on a new/aged session) must NOT be ranked on, so we surface an
        # empty pool for the scoring path rather than stale opportunities.
        if result.usable_as_fresh:
            return result.value or []
        return []

    # -- public per-market accessors (reused by Morning Brief) ------------
    def market_top(self, market: Market, limit: int = 50) -> List[Opportunity]:
        """Ranked opportunities for a single market (never raises).

        Public, read-only accessor over the existing ranking pipeline so other
        features (e.g. the AI Morning Brief) can reuse Radar output without
        recomputing any scoring/indicators.
        """
        return self._safe_for(market, limit=limit)

    def market_multibaggers(
        self, market: Market, limit: int = 50
    ) -> List[Opportunity]:
        """Multibagger-qualifying opportunities within a single market."""
        return [o for o in self._safe_for(market, limit=limit)
                if _is_multibagger(o)]

    def market_regime(self, market: Market, limit: int = 50) -> str:
        """The bull/neutral/bear regime for a single market scan."""
        top = self._safe_for(market, limit=limit)
        return top[0].market_regime if top else REGIME_NEUTRAL

    def _global_pool(self, per_market: int = 30) -> List[Opportunity]:
        """Ranked opportunities across all markets (deduped, sorted)."""
        pool: List[Opportunity] = []
        for mkt in self._markets:
            # _safe_for is cached + never raises (one bad market can't break
            # the radar and won't re-run engine.screen() within the TTL).
            pool.extend(self._safe_for(mkt, limit=per_market))
        pool.sort(key=lambda o: o.composite_rank_score, reverse=True)
        return pool

    def _freshness_market(self) -> Market:
        """Market used to gate the aggregate radar caches (any-open = strict)."""
        for m in self._markets:
            if get_market_session_state(m) is MarketSessionState.OPEN:
                return m
        return self._markets[0] if self._markets else Market.IDX

    def _fresh_fields(self, result) -> dict:
        d = result.decision
        return {
            "cached": result.cached,
            "stale": d.stale,
            "fallback": d.fallback,
            "freshness": d.freshness,
            "data_available": result.value is not None,
        }

    # -- Phase 2: /v1/radar/opportunities --------------------------------
    def opportunities(self) -> OpportunitiesResponse:
        result = self._cache.get_or_build_fresh(
            CACHE_NAMESPACE, "radar_opportunities",
            self._build_opportunities, self._freshness_market(),
        )
        if result.value is None:
            return OpportunitiesResponse(
                generated_at=_now_iso(), stale=True, fallback=True,
                freshness="unavailable", data_available=False,
            )
        return result.value.model_copy(update=self._fresh_fields(result))

    def _build_opportunities(self) -> OpportunitiesResponse:
        global_pool = self._global_pool()
        us = self._safe_for(Market.US)
        idx = self._safe_for(Market.IDX)
        multibaggers = [
            o for o in global_pool if _is_multibagger(o)
        ][:10]
        return OpportunitiesResponse(
            generated_at=_now_iso(),
            global_top10=global_pool[:10],
            us_top10=us[:10],
            idx_top10=idx[:10],
            multibagger_candidates=multibaggers,
        )

    # -- Phase 3: /v1/radar/daily ----------------------------------------
    def daily(self, count: int = 5) -> DailyPicksResponse:
        result = self._cache.get_or_build_fresh(
            CACHE_NAMESPACE, f"radar_daily_{count}",
            lambda: self._build_daily(count), self._freshness_market(),
        )
        if result.value is None:
            return DailyPicksResponse(
                generated_at=_now_iso(), date=_today(), stale=True,
                fallback=True, freshness="unavailable", data_available=False,
            )
        return result.value.model_copy(update=self._fresh_fields(result))

    def _build_daily(self, count: int = 5) -> DailyPicksResponse:
        pool = self._global_pool()
        picks: List[DailyPick] = []
        for i, o in enumerate(pool[:count], start=1):
            picks.append(
                DailyPick(
                    rank=i,
                    symbol=o.symbol,
                    market=o.market,
                    name=o.name,
                    score=o.score,
                    signal=o.signal,
                    recommendation=o.recommendation,
                )
            )
        return DailyPicksResponse(
            generated_at=_now_iso(), date=_today(), picks=picks
        )

    # -- Phase 4: /v1/radar/multibagger ----------------------------------
    def multibagger(self) -> MultibaggerResponse:
        result = self._cache.get_or_build_fresh(
            CACHE_NAMESPACE, "radar_multibagger",
            self._build_multibagger, self._freshness_market(),
        )
        if result.value is None:
            return MultibaggerResponse(
                generated_at=_now_iso(), stale=True, fallback=True,
                freshness="unavailable", data_available=False,
            )
        return result.value.model_copy(update=self._fresh_fields(result))

    def _build_multibagger(self) -> MultibaggerResponse:
        pool = self._global_pool()
        candidates: List[MultibaggerCandidate] = []
        for o in pool:
            if not _is_multibagger(o):
                continue
            candidates.append(
                MultibaggerCandidate(
                    symbol=o.symbol,
                    market=o.market,
                    name=o.name,
                    score=o.score,
                    signal=o.signal,
                    conviction=_conviction(o),
                    risk_level=_risk_level(o),
                    relative_strength=o.relative_strength,
                    liquidity=o.liquidity,
                    market_regime=o.market_regime,
                    reason=(
                        "Strong trend + high relative strength + strong "
                        "liquidity, score > 85 in a bull regime."
                    ),
                )
            )
        return MultibaggerResponse(
            generated_at=_now_iso(),
            criteria=[
                "Strong trend",
                "High relative strength",
                "Strong liquidity",
                f"Score > {int(MULTIBAGGER_MIN_SCORE)}",
                "Bull market regime",
            ],
            candidates=candidates[:20],
        )


# --- pure helpers -----------------------------------------------------------
def _is_multibagger(o: Opportunity) -> bool:
    return (
        o.score > MULTIBAGGER_MIN_SCORE
        and o.relative_strength >= MULTIBAGGER_MIN_RS
        and o.market_regime == REGIME_BULL
        and _liquidity_ok(o)
    )


def _liquidity_ok(o: Opportunity) -> bool:
    # Liquidity is captured in the composite + RS; require positive turnover so
    # an illiquid name can't be flagged as a multibagger.
    return o.liquidity > 0


def _recommendation(signal: str, score: float) -> str:
    sig = (signal or "HOLD").upper()
    if sig == "BUY" and score >= 85:
        return "Strong Buy"
    if sig == "BUY":
        return "Buy"
    if sig == "SELL":
        return "Avoid / Reduce"
    return "Watch"


def _reason(match, rs: float, liq: float, regime: str) -> str:
    bits: List[str] = [f"Score {match.score:.0f}"]
    if rs >= 70:
        bits.append("leading relative strength")
    elif rs >= 50:
        bits.append("above-median relative strength")
    if liq >= 70:
        bits.append("strong liquidity")
    if ScreenerCategory.turnaround_multibagger in match.categories:
        bits.append("turnaround setup")
    bits.append(f"{regime.lower()} regime")
    return ", ".join(bits) + "."


def _conviction(o: Opportunity) -> str:
    if o.score >= 92 and o.relative_strength >= 80:
        return "HIGH"
    if o.score >= 88:
        return "MODERATE"
    return "SPECULATIVE"


def _risk_level(o: Opportunity) -> str:
    # Higher liquidity + stronger RS => lower risk; multibaggers stay >= MEDIUM.
    if o.relative_strength >= 85 and o.liquidity > 0:
        return "MEDIUM"
    return "HIGH"
