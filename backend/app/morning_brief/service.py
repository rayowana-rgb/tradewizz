"""AI Morning Brief service — rule-based, cached once per market session.

Inputs are derived ENTIRELY from the existing Opportunity Radar
(`RadarService`), which itself reuses the real screener engine + ranking +
market-regime. This module only:

  * picks the top opportunity + top multibagger candidate for a market,
  * derives the "strongest sector" with a lightweight keyword classifier
    (relative-strength weighted), and
  * writes a plain-language headline + notes.

No LLM. No new scoring/indicators. No broker contact. The brief is cached once
per market per UTC session date; the cache is in-memory and best-effort.
"""

from __future__ import annotations

from datetime import datetime, timezone
from threading import Lock
from typing import Dict, List, Optional, Protocol, Tuple

from ..models import Market
from ..radar.models import Opportunity
from .models import BriefPick, MorningBrief


class RadarLike(Protocol):
    def market_top(self, market: Market, limit: int = 50) -> List[Opportunity]: ...
    def market_multibaggers(
        self, market: Market, limit: int = 50
    ) -> List[Opportunity]: ...
    def market_regime(self, market: Market, limit: int = 50) -> str: ...


# Lightweight sector keyword map. Names/symbols are matched case-insensitively;
# the first matching sector wins. This is intentionally simple (rule-based) —
# the universe files carry no sector column, so we classify from the name.
_SECTOR_KEYWORDS: List[Tuple[str, Tuple[str, ...]]] = [
    ("Semiconductors", ("semiconductor", "chip", "nvidia", "nvda", "amd",
                         "tsmc", "micron", "asml", "arm")),
    ("Technology", ("tech", "software", "cloud", "data", "cyber", "ai",
                    "internet", "platform", "digital", "palantir", "pltr",
                    "microsoft", "apple", "google", "meta", "goto")),
    ("Banking & Finance", ("bank", "finance", "financial", "credit", "capital",
                           "insurance", "bbca", "bbri", "bmri", "bri",
                           "securities", "asset")),
    ("Energy", ("energy", "oil", "gas", "petro", "coal", "solar", "power",
                "electric", "renewable", "pgas", "pertamina")),
    ("Materials & Mining", ("mining", "metal", "gold", "nickel", "copper",
                            "steel", "cement", "chemical", "material",
                            "antm", "inco", "mdka", "tpia")),
    ("Consumer", ("consumer", "retail", "food", "beverage", "tobacco",
                  "restaurant", "apparel", "unilever", "indofood", "icbp",
                  "myor")),
    ("Healthcare", ("health", "pharma", "medical", "bio", "hospital",
                    "kalbe", "klbf")),
    ("Industrials", ("industrial", "construction", "infrastructure",
                     "logistics", "transport", "manufactur", "machinery",
                     "automotive", "auto")),
    ("Telecom", ("telecom", "telco", "communication", "telkom", "tlkm",
                 "isat", "wireless")),
    ("Real Estate", ("property", "real estate", "reit", "estate", "land")),
]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session_date() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _classify_sector(name: str, symbol: str) -> Optional[str]:
    hay = f"{name} {symbol}".lower()
    for sector, keywords in _SECTOR_KEYWORDS:
        for kw in keywords:
            if kw in hay:
                return sector
    return None


def _strongest_sector(opps: List[Opportunity]) -> str:
    """Sector with the highest aggregate (score * weight) across the top names.

    Weighted by composite rank so leaders count more. Unclassified names are
    bucketed under "Broad Market" and only win if nothing else classifies.
    """
    if not opps:
        return "—"
    weights: Dict[str, float] = {}
    for o in opps[:25]:
        sector = _classify_sector(o.name, o.symbol) or "Broad Market"
        # Weight by score; leaders (top of the list) get a mild rank bonus.
        weights[sector] = weights.get(sector, 0.0) + max(0.0, o.score)
    classified = {k: v for k, v in weights.items() if k != "Broad Market"}
    pool = classified or weights
    return max(pool.items(), key=lambda kv: kv[1])[0]


def _pick(o: Opportunity) -> BriefPick:
    return BriefPick(
        symbol=o.symbol,
        market=o.market,
        name=o.name,
        score=o.score,
        signal=o.signal,
        reason=o.opportunity_reason or o.recommendation,
    )


def _multibagger_pick(o: Opportunity) -> BriefPick:
    return BriefPick(
        symbol=o.symbol,
        market=o.market,
        name=o.name,
        score=o.score,
        signal=o.signal,
        reason=(o.opportunity_reason
                or "Acceleration trend + relative strength."),
    )


def _headline(market: Market, regime: str, top: Optional[BriefPick]) -> str:
    label = {"BULL": "bullish", "NEUTRAL": "mixed", "BEAR": "defensive"}.get(
        regime, "mixed"
    )
    if top is None:
        return (
            f"{market.value} session looks {label}; no standout opportunity "
            "surfaced from the latest scan."
        )
    return (
        f"{market.value} session looks {label}. Top opportunity: "
        f"{top.symbol} (score {top.score:.0f})."
    )


class MorningBriefService:
    """Builds + caches a once-per-session brief per market."""

    def __init__(self, radar: RadarLike):
        self._radar = radar
        self._cache: Dict[Tuple[str, str], MorningBrief] = {}
        self._lock = Lock()

    def _build(self, market: Market) -> MorningBrief:
        top = self._radar.market_top(market, limit=50)
        regime = top[0].market_regime if top else self._radar.market_regime(
            market
        )
        strongest = _strongest_sector(top)

        top_pick = _pick(top[0]) if top else None
        mbs = self._radar.market_multibaggers(market, limit=50)
        mb_pick = _multibagger_pick(mbs[0]) if mbs else None

        notes: List[str] = []
        if regime == "BULL":
            notes.append(
                "Breadth is positive — momentum setups are favored today."
            )
        elif regime == "BEAR":
            notes.append(
                "Breadth is weak — prioritize quality and capital protection."
            )
        else:
            notes.append("Breadth is mixed — be selective.")
        if strongest not in ("—", "Broad Market"):
            notes.append(f"Strongest sector right now: {strongest}.")
        if mb_pick is not None:
            notes.append(
                f"Multibagger watch: {mb_pick.symbol} "
                f"(score {mb_pick.score:.0f})."
            )

        return MorningBrief(
            market=market,
            generated_at=_now_iso(),
            session_date=_session_date(),
            market_regime=regime,
            strongest_sector=strongest,
            headline=_headline(market, regime, top_pick),
            top_opportunity=top_pick,
            top_multibagger=mb_pick,
            notes=notes,
            simulated=False,
            cached=False,
        )

    def brief(self, market: Market, *, force: bool = False) -> MorningBrief:
        """Return the cached brief for today's session, building it if needed."""
        key = (market.value, _session_date())
        if not force:
            with self._lock:
                hit = self._cache.get(key)
            if hit is not None:
                return hit.model_copy(update={"cached": True})
        built = self._build(market)
        with self._lock:
            self._cache[key] = built
        return built

    def clear_cache(self) -> None:
        with self._lock:
            self._cache.clear()
