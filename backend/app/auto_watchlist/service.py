"""Auto Watchlist AI service — rule-based daily watchlist suggestions.

Suggestion logic (Phase 3 spec), all derived from the EXISTING Radar pipeline
(screener + ranking + regime) and Daily Picks / Multibagger Finder:

  * Top opportunity per market, score >= min_score (default 85), signal == BUY.
  * Avoid symbols already on the user's watchlist (passed by the client).
  * Avoid symbols already owned (open simulated position) unless score >= 92.
  * Prefer liquid names (positive turnover).
  * Prefer markets with a bullish or neutral regime (bearish markets excluded).
  * Cap at max_per_day (default 10).

Applying a suggestion records server-side source metadata (an audit trail) and
returns the applied items so the client can add them to its watchlist. No LLM,
no broker contact, no accounting.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Callable, List, Optional, Protocol

from ..models import Market
from ..radar.models import Opportunity
from .models import (
    AppliedSuggestion,
    ApplyItem,
    AutoWatchlistSettings,
    AutoWatchlistSuggestion,
    AutoWatchlistSuggestionsResponse,
    ORIGIN_DAILY_PICK,
    ORIGIN_MULTIBAGGER,
    ORIGIN_RADAR,
    SOURCE_AUTO_WATCHLIST_AI,
)
from .store import AutoWatchlistStore

# A symbol already owned is only re-suggested at/above this score.
OWNED_OVERRIDE_SCORE = 92.0
REGIME_BEAR = "BEAR"

DEFAULT_SETTINGS = AutoWatchlistSettings()


class RadarLike(Protocol):
    def market_top(self, market: Market, limit: int = 50) -> List[Opportunity]: ...
    def market_multibaggers(
        self, market: Market, limit: int = 50
    ) -> List[Opportunity]: ...


# positions_provider(user_id) -> list of objects with .symbol / .market.
PositionsProvider = Callable[[int], List]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session_date() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _key(market: Market, symbol: str) -> str:
    return f"{market.value}:{symbol.upper()}"


def _normalize_existing(existing: List[str]) -> set:
    """Accept "MARKET:SYMBOL" or bare "SYMBOL"; index both forms."""
    out = set()
    for e in existing or []:
        if not e:
            continue
        e = e.strip().upper()
        out.add(e)
        if ":" in e:
            out.add(e.split(":", 1)[1])  # bare symbol too
    return out


class AutoWatchlistService:
    def __init__(
        self,
        radar: RadarLike,
        store: AutoWatchlistStore,
        positions_provider: Optional[PositionsProvider] = None,
        markets: Optional[List[Market]] = None,
        notify: Optional[Callable[[int, AutoWatchlistSuggestion], None]] = None,
    ):
        self._radar = radar
        self._store = store
        self._positions = positions_provider
        self._markets = markets or list(Market)
        self._notify = notify

    # -- settings --------------------------------------------------------
    def get_settings(self, user_id: int) -> AutoWatchlistSettings:
        return self._store.get_settings(user_id) or DEFAULT_SETTINGS.model_copy()

    def save_settings(
        self, user_id: int, settings: AutoWatchlistSettings
    ) -> AutoWatchlistSettings:
        self._store.save_settings(user_id, settings)
        return settings

    # -- suggestions -----------------------------------------------------
    def _owned_keys(self, user_id: int) -> set:
        if self._positions is None:
            return set()
        try:
            return {_key(p.market, p.symbol) for p in self._positions(user_id)}
        except Exception:  # noqa: BLE001
            return set()

    def suggestions(
        self, user_id: int, existing: Optional[List[str]] = None
    ) -> AutoWatchlistSuggestionsResponse:
        settings = self.get_settings(user_id)
        if not settings.enabled:
            return AutoWatchlistSuggestionsResponse(
                generated_at=_now_iso(),
                session_date=_session_date(),
                suggestions=[],
                max_suggestions_per_day=settings.max_per_day,
                enabled=False,
            )

        markets = settings.markets or self._markets
        owned = self._owned_keys(user_id)
        existing_keys = _normalize_existing(existing or [])
        already_applied = set(self._store.applied_symbols(user_id))

        seen: set = set()
        out: List[AutoWatchlistSuggestion] = []

        for market in markets:
            top = self._radar.market_top(market, limit=50)
            if not top:
                continue
            regime = top[0].market_regime
            # Prefer bullish/neutral regimes; skip bearish markets entirely.
            if regime == REGIME_BEAR:
                continue
            for o in top:
                s = self._maybe_suggestion(
                    o, settings, owned, existing_keys, already_applied,
                    seen, origin=ORIGIN_RADAR,
                )
                if s is not None:
                    out.append(s)

        # Multibagger candidates (high-conviction additions).
        if settings.include_multibagger:
            for market in markets:
                for o in self._radar.market_multibaggers(market, limit=50):
                    s = self._maybe_suggestion(
                        o, settings, owned, existing_keys, already_applied,
                        seen, origin=ORIGIN_MULTIBAGGER,
                    )
                    if s is not None:
                        out.append(s)

        # Rank by score (desc), keep liquid names first on ties, then cap.
        out.sort(key=lambda s: (s.score, s.liquidity), reverse=True)
        out = out[: max(0, settings.max_per_day)]

        return AutoWatchlistSuggestionsResponse(
            generated_at=_now_iso(),
            session_date=_session_date(),
            suggestions=out,
            max_suggestions_per_day=settings.max_per_day,
            enabled=True,
        )

    def _maybe_suggestion(
        self, o: Opportunity, settings, owned, existing_keys, already_applied,
        seen, *, origin: str,
    ) -> Optional[AutoWatchlistSuggestion]:
        k = _key(o.market, o.symbol)
        bare = o.symbol.upper()
        if k in seen:
            return None
        # Score gate + BUY-only.
        if o.score < settings.min_score:
            return None
        if (o.signal or "").upper() != "BUY":
            return None
        # Prefer liquid names.
        if o.liquidity <= 0:
            return None
        # Avoid duplicates already on the watchlist (client) or applied (server).
        if k in existing_keys or bare in existing_keys or k in already_applied:
            return None
        # Avoid owned positions unless score >= 92.
        is_owned = k in owned
        if is_owned and o.score < OWNED_OVERRIDE_SCORE:
            return None

        seen.add(k)
        return AutoWatchlistSuggestion(
            symbol=o.symbol,
            market=o.market,
            name=o.name,
            score=o.score,
            signal=o.signal,
            origin=origin,
            reason=o.opportunity_reason or o.recommendation,
            market_regime=o.market_regime,
            relative_strength=o.relative_strength,
            liquidity=o.liquidity,
            owned=is_owned,
        )

    # -- apply -----------------------------------------------------------
    def apply(
        self,
        user_id: int,
        items: Optional[List[ApplyItem]] = None,
        existing: Optional[List[str]] = None,
    ) -> tuple:
        """Apply selected suggestions (or all of today's when items is None).

        Returns (applied, skipped). Does NOT overwrite an existing watchlist
        item: anything in ``existing`` (client watchlist) is skipped.
        """
        suggestions = self.suggestions(user_id, existing=existing).suggestions
        by_key = {_key(s.market, s.symbol): s for s in suggestions}

        if items:
            wanted = [_key(it.market, it.symbol) for it in items]
        else:
            wanted = list(by_key.keys())  # Apply All

        existing_keys = _normalize_existing(existing or [])
        applied: List[AppliedSuggestion] = []
        skipped: List[str] = []

        for key in wanted:
            sug = by_key.get(key)
            bare = key.split(":", 1)[1] if ":" in key else key
            if sug is None or key in existing_keys or bare in existing_keys:
                skipped.append(key)
                continue
            entry = AppliedSuggestion(
                symbol=sug.symbol,
                market=sug.market,
                name=sug.name,
                source=SOURCE_AUTO_WATCHLIST_AI,
                reason=sug.reason,
                score_at_added=sug.score,
                market_regime_at_added=sug.market_regime,
                added_at=_now_iso(),
            )
            self._store.add_applied(user_id, entry)
            applied.append(entry)
            if self._notify is not None:
                try:
                    self._notify(user_id, sug)
                except Exception:  # noqa: BLE001 - notifications best-effort
                    pass

        return applied, skipped
