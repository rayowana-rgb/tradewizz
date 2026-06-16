"""Snapshot service (Phase A/B/C/D).

Aggregates existing service OUTPUT into snapshot documents and caches them
server-side with per-section TTLs (Phase D). Contains no scoring/ranking/
accounting — it only calls the injected services and serializes their results.

Design:
  * Section builders are small callables that return a JSON-able dict/list, or
    raise/return empty on failure.
  * ``_section(...)`` runs a builder behind its TTL: fresh cache -> reuse (no
    recompute, no Yahoo); stale/missing -> rebuild; on failure keep the last
    good cached section (Phase N reliability).
  * The whole document is also cached so an unchanged dashboard request can be
    served straight from disk.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Optional

from ..models import Market
from . import cache as ttl
from .cache import SnapshotCache
from .models import (
    DashboardSnapshot,
    PortfolioSnapshot,
    WatchlistSnapshot,
)


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _dump(obj: Any) -> Any:
    """Serialize a pydantic model (or list of them) to JSON-able data."""
    if obj is None:
        return None
    if isinstance(obj, list):
        return [_dump(o) for o in obj]
    if hasattr(obj, "model_dump"):
        return obj.model_dump(mode="json")
    if hasattr(obj, "to_dict"):
        return obj.to_dict()
    return obj


class SnapshotService:
    """Builds + caches dashboard / portfolio / watchlist snapshots.

    All providers are optional so the service degrades gracefully when a
    subsystem is unavailable (the section is simply ``None`` / empty and the
    app keeps its own cached copy).
    """

    def __init__(
        self,
        *,
        cache: Optional[SnapshotCache] = None,
        indices_provider: Optional[Callable[[], Any]] = None,
        brief_provider: Optional[Callable[[Market], Any]] = None,
        rotation_provider: Optional[Callable[[], Any]] = None,
        opportunities_provider: Optional[Callable[[], Any]] = None,
        daily_provider: Optional[Callable[[], Any]] = None,
        multibagger_provider: Optional[Callable[[], Any]] = None,
        watchlist_provider: Optional[Callable[[int, Optional[List[str]]], Any]] = None,
        notifications_provider: Optional[Callable[[int], Any]] = None,
        account_provider: Optional[Callable[[int], Any]] = None,
        positions_provider: Optional[Callable[[int], Any]] = None,
        health_provider: Optional[Callable[[int], Any]] = None,
        quality_provider: Optional[Callable[[int], Any]] = None,
        manager_provider: Optional[Callable[[int], Any]] = None,
    ) -> None:
        self.cache = cache or SnapshotCache()
        self._indices = indices_provider
        self._brief = brief_provider
        self._rotation = rotation_provider
        self._opportunities = opportunities_provider
        self._daily = daily_provider
        self._multibagger = multibagger_provider
        self._watchlist = watchlist_provider
        self._notifications = notifications_provider
        self._account = account_provider
        self._positions = positions_provider
        self._health = health_provider
        self._quality = quality_provider
        self._manager = manager_provider

    # -- section engine ----------------------------------------------------
    def _section(
        self,
        name: str,
        ttl_seconds: float,
        builder: Callable[[], Any],
        *,
        force: bool = False,
        block: bool = True,
    ) -> Any:
        """Return a fresh-or-cached section payload.

        Fresh cache within TTL -> reuse (no Yahoo, no recompute).
        Otherwise rebuild; on failure/empty keep the last good cached section.

        When ``block`` is False (the live request path), a *stale but cached*
        section is served as-is rather than rebuilt synchronously: the
        background scheduler owns refreshes, so a slow Yahoo rebuild can never
        hang the request and blank the dashboard. We only build inline when
        forced or when there is no cached value at all (cold start).
        """
        if not force and self.cache.is_fresh(name, ttl_seconds):
            payload, _age = self.cache.get(name)
            if payload is not None:
                return payload
        if not force and not block:
            # Stale: serve last-good cache without blocking on a rebuild.
            payload, _age = self.cache.get(name)
            if payload is not None:
                return payload
        try:
            built = _dump(builder())
        except Exception:  # noqa: BLE001
            built = None
        if self.cache.put_guarded(name, built):
            return built
        # Build failed/empty: serve previous good snapshot if any (Phase N).
        payload, _age = self.cache.get(name)
        return payload if payload is not None else built

    def _age(self, name: str) -> float:
        age = self.cache.age(name)
        return round(age, 3) if age is not None else -1.0

    # -- Phase A: dashboard -------------------------------------------------
    def dashboard(
        self, market: Market, *, force: bool = False, block: bool = True
    ) -> DashboardSnapshot:
        mk = market.value

        indices = self._section(
            "indices", ttl.TTL_INDICES,
            lambda: {"indices": _dump(self._indices())} if self._indices else None,
            force=force, block=block,
        )
        brief = self._section(
            f"morning_brief_{mk}", ttl.TTL_MORNING_BRIEF,
            lambda: _dump(self._brief(market)) if self._brief else None,
            force=force, block=block,
        )
        rotation = self._section(
            "rotation", ttl.TTL_ROTATION,
            lambda: _dump(self._rotation()) if self._rotation else None,
            force=force, block=block,
        )
        radar = self._section(
            "radar", ttl.TTL_RADAR,
            lambda: _dump(self._opportunities()) if self._opportunities else None,
            force=force, block=block,
        )
        daily = self._section(
            "daily_picks", ttl.TTL_DAILY_PICKS,
            lambda: _dump(self._daily()) if self._daily else None,
            force=force, block=block,
        )
        multibagger = self._section(
            "multibagger", ttl.TTL_MULTIBAGGER,
            lambda: _dump(self._multibagger()) if self._multibagger else None,
            force=force, block=block,
        )
        watchlist = self._section(
            "watchlist_ai", ttl.TTL_WATCHLIST_AI,
            lambda: _dump(self._watchlist(0, None)) if self._watchlist else None,
            force=force, block=block,
        )
        notifications = self._section(
            "notifications", ttl.TTL_NOTIFICATIONS,
            lambda: self._notifications_payload(0),
            force=force, block=block,
        )

        snap = DashboardSnapshot(
            generated_at=_now_iso(),
            market=mk,
            indices=indices,
            morning_brief=brief,
            rotation=rotation,
            radar=radar,
            daily_picks=daily,
            multibagger=multibagger,
            watchlist_ai=watchlist,
            notifications=notifications,
            section_ages={
                "indices": self._age("indices"),
                "morning_brief": self._age(f"morning_brief_{mk}"),
                "rotation": self._age("rotation"),
                "radar": self._age("radar"),
                "daily_picks": self._age("daily_picks"),
                "multibagger": self._age("multibagger"),
                "watchlist_ai": self._age("watchlist_ai"),
                "notifications": self._age("notifications"),
            },
        )
        self.cache.put(f"dashboard_{mk}", snap.model_dump(mode="json"))
        return snap

    # -- Phase B: portfolio (per user) -------------------------------------
    def portfolio(self, user_id: int, *, force: bool = False) -> PortfolioSnapshot:
        def _call(fn, *a):
            if fn is None:
                return None
            try:
                return _dump(fn(*a))
            except Exception:  # noqa: BLE001
                return None

        account = _call(self._account, user_id)
        positions = _call(self._positions, user_id) or []
        health = _call(self._health, user_id)
        quality = _call(self._quality, user_id) or []
        manager = _call(self._manager, user_id)

        snap = PortfolioSnapshot(
            generated_at=_now_iso(),
            account=account,
            positions=positions if isinstance(positions, list) else [],
            portfolio_health=health,
            portfolio_quality=quality if isinstance(quality, list) else [],
            portfolio_manager=manager,
        )
        self.cache.put_guarded(
            f"portfolio_{user_id}", snap.model_dump(mode="json")
        )
        return snap

    # -- Phase C: watchlist (per user) -------------------------------------
    def watchlist(
        self,
        user_id: int,
        market: Market,
        *,
        existing: Optional[List[str]] = None,
        force: bool = False,
    ) -> WatchlistSnapshot:
        watchlist_ai: List[Dict[str, Any]] = []
        if self._watchlist is not None:
            try:
                payload = _dump(self._watchlist(user_id, existing))
                watchlist_ai = self._suggestions_list(payload)
            except Exception:  # noqa: BLE001
                watchlist_ai = []

        rotation = self._section(
            "rotation", ttl.TTL_ROTATION,
            lambda: _dump(self._rotation()) if self._rotation else None,
            force=force,
        )

        daily_list: List[Dict[str, Any]] = []
        daily = self._section(
            "daily_picks", ttl.TTL_DAILY_PICKS,
            lambda: _dump(self._daily()) if self._daily else None,
            force=force,
        )
        if isinstance(daily, dict):
            for key in ("picks", "daily_picks", "items", "opportunities"):
                v = daily.get(key)
                if isinstance(v, list):
                    daily_list = v
                    break

        snap = WatchlistSnapshot(
            generated_at=_now_iso(),
            market=market.value,
            watchlist_ai=watchlist_ai,
            rotation=rotation,
            daily_picks=daily_list,
        )
        self.cache.put(f"watchlist_{user_id}_{market.value}",
                       snap.model_dump(mode="json"))
        return snap

    # -- helpers -----------------------------------------------------------
    def _notifications_payload(self, user_id: int) -> Optional[Dict[str, Any]]:
        if self._notifications is None:
            return None
        try:
            items, unread = self._notifications(user_id)
            return {
                "notifications": _dump(items),
                "unread_count": unread,
            }
        except Exception:  # noqa: BLE001
            return None

    @staticmethod
    def _suggestions_list(payload: Any) -> List[Dict[str, Any]]:
        if isinstance(payload, dict):
            for key in ("suggestions", "items", "watchlist", "picks"):
                v = payload.get(key)
                if isinstance(v, list):
                    return v
        if isinstance(payload, list):
            return payload
        return []
