"""Tier definitions, limits, and the feature-entitlement matrix.

Single source of truth for what FREE / PRO / ELITE can do. Both the backend
gating and the Flutter paywall read from the same matrix (the matrix is exposed
verbatim via GET /v1/subscription/plans), so the UI and the server never drift.

Pricing is a placeholder for the app store / billing integration that will be
wired later. No payment is taken here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

# --- Tier identifiers -------------------------------------------------------
FREE = "FREE"
PRO = "PRO"
ELITE = "ELITE"

# Ordered low -> high so we can answer "does tier X include tier Y's features".
TIER_ORDER: List[str] = [FREE, PRO, ELITE]


# --- Feature flags (stable wire names; mirrored in the Flutter app) ---------
# Research/AI/simulation features only. There is intentionally NO broker or
# real-money feature here.
FEATURE_GLOBAL_MARKETS = "global_markets"
FEATURE_ADVANCED_SCORE = "advanced_score_breakdown"
FEATURE_OPPORTUNITY_RADAR = "opportunity_radar"
FEATURE_DAILY_PICKS = "daily_top_opportunities"
FEATURE_MULTIBAGGER = "multibagger_finder"
FEATURE_PORTFOLIO_HEALTH = "portfolio_health"
FEATURE_RISK_ANALYSIS = "risk_analysis"
FEATURE_CONCENTRATION = "concentration_analysis"
FEATURE_EXIT_WARNINGS = "exit_warnings"
FEATURE_POSITION_QUALITY = "position_quality"
FEATURE_ELITE_OPPORTUNITIES = "elite_opportunities"

ALL_FEATURES: List[str] = [
    FEATURE_GLOBAL_MARKETS,
    FEATURE_ADVANCED_SCORE,
    FEATURE_OPPORTUNITY_RADAR,
    FEATURE_DAILY_PICKS,
    FEATURE_MULTIBAGGER,
    FEATURE_PORTFOLIO_HEALTH,
    FEATURE_RISK_ANALYSIS,
    FEATURE_CONCENTRATION,
    FEATURE_EXIT_WARNINGS,
    FEATURE_POSITION_QUALITY,
    FEATURE_ELITE_OPPORTUNITIES,
]

# Human-readable labels for the comparison table.
FEATURE_LABELS: Dict[str, str] = {
    FEATURE_GLOBAL_MARKETS: "Global markets",
    FEATURE_ADVANCED_SCORE: "Advanced score breakdown",
    FEATURE_OPPORTUNITY_RADAR: "AI Opportunity Radar",
    FEATURE_DAILY_PICKS: "Daily Top Opportunities",
    FEATURE_MULTIBAGGER: "Multibagger Finder",
    FEATURE_PORTFOLIO_HEALTH: "Portfolio Health Score",
    FEATURE_RISK_ANALYSIS: "Risk Analysis",
    FEATURE_CONCENTRATION: "Concentration Analysis",
    FEATURE_EXIT_WARNINGS: "Exit Warnings",
    FEATURE_POSITION_QUALITY: "Position Quality Score",
    FEATURE_ELITE_OPPORTUNITIES: "Elite Opportunities",
}

# Sentinel: an unlimited numeric limit.
UNLIMITED = -1


@dataclass(frozen=True)
class TierLimits:
    """Numeric usage limits for a tier. -1 (UNLIMITED) means no cap."""

    watchlist_max: int
    analysis_per_day: int
    screener_max_results: int


@dataclass(frozen=True)
class Tier:
    """A subscription tier: its limits, included features, and placeholder price."""

    name: str
    price_usd_month: float
    limits: TierLimits
    features: List[str] = field(default_factory=list)
    description: str = ""

    def has_feature(self, feature: str) -> bool:
        return feature in self.features


# --- The tier matrix --------------------------------------------------------
# FREE: capped, no premium radar/portfolio features.
# PRO: unlimited core + radar + daily picks + advanced score.
# ELITE: everything in PRO + portfolio-health/risk/quality/multibagger/elite.

_PRO_FEATURES = [
    FEATURE_GLOBAL_MARKETS,
    FEATURE_ADVANCED_SCORE,
    FEATURE_OPPORTUNITY_RADAR,
    FEATURE_DAILY_PICKS,
]

_ELITE_FEATURES = _PRO_FEATURES + [
    FEATURE_PORTFOLIO_HEALTH,
    FEATURE_RISK_ANALYSIS,
    FEATURE_CONCENTRATION,
    FEATURE_EXIT_WARNINGS,
    FEATURE_POSITION_QUALITY,
    FEATURE_MULTIBAGGER,
    FEATURE_ELITE_OPPORTUNITIES,
]

TIERS: Dict[str, Tier] = {
    FREE: Tier(
        name=FREE,
        price_usd_month=0.0,
        limits=TierLimits(
            watchlist_max=20,
            analysis_per_day=5,
            screener_max_results=20,
        ),
        features=[FEATURE_GLOBAL_MARKETS],
        description="Get started: global screener, limited analysis & watchlist.",
    ),
    PRO: Tier(
        name=PRO,
        price_usd_month=9.99,
        limits=TierLimits(
            watchlist_max=UNLIMITED,
            analysis_per_day=UNLIMITED,
            screener_max_results=UNLIMITED,
        ),
        features=list(_PRO_FEATURES),
        description="Unlimited research + AI Opportunity Radar & Daily Picks.",
    ),
    ELITE: Tier(
        name=ELITE,
        price_usd_month=29.99,
        limits=TierLimits(
            watchlist_max=UNLIMITED,
            analysis_per_day=UNLIMITED,
            screener_max_results=UNLIMITED,
        ),
        features=list(_ELITE_FEATURES),
        description="Everything in Pro + Portfolio Health, Risk & Multibagger.",
    ),
}


def normalize_tier(tier: Optional[str]) -> str:
    """Coerce an arbitrary string to a known tier; default to FREE."""
    if not tier:
        return FREE
    name = str(tier).strip().upper()
    return name if name in TIERS else FREE


def limits_for(tier: str) -> TierLimits:
    """Numeric limits for a tier (FREE for unknown)."""
    return TIERS[normalize_tier(tier)].limits


def tier_includes(tier: str, feature: str) -> bool:
    """Whether ``tier`` is entitled to ``feature``."""
    return TIERS[normalize_tier(tier)].has_feature(feature)


def min_tier_for(feature: str) -> str:
    """The cheapest tier that unlocks ``feature`` (ELITE if none, defensively)."""
    for name in TIER_ORDER:
        if TIERS[name].has_feature(feature):
            return name
    return ELITE


def is_unlimited(value: int) -> bool:
    return value == UNLIMITED


def feature_matrix() -> Dict[str, object]:
    """Serializable plan comparison for the upgrade screen.

    Returns tiers (with prices + numeric limits) and a per-feature table of
    which tier unlocks it, so the Flutter paywall renders directly from this.
    """
    return {
        "tiers": [
            {
                "tier": t.name,
                "price_usd_month": t.price_usd_month,
                "description": t.description,
                "limits": {
                    "watchlist_max": t.limits.watchlist_max,
                    "analysis_per_day": t.limits.analysis_per_day,
                    "screener_max_results": t.limits.screener_max_results,
                },
                "features": list(t.features),
            }
            for t in (TIERS[name] for name in TIER_ORDER)
        ],
        "features": [
            {
                "key": f,
                "label": FEATURE_LABELS.get(f, f),
                "min_tier": min_tier_for(f),
                "tiers": {
                    name: TIERS[name].has_feature(f) for name in TIER_ORDER
                },
            }
            for f in ALL_FEATURES
        ],
    }
