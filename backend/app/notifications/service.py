"""Notification Engine service — generates in-app notifications from signals.

Conditions (Phase 2 spec):
  1. New Elite Opportunity     -> opportunity score >= 90
  2. New Multibagger Candidate -> a multibagger candidate is present
  3. Portfolio Health Warning  -> health score dropped > 15 vs last seen
  4. Daily Pick Published      -> new daily picks generated (per session date)

Generation is dedup'd (a stable dedup_key per condition+session) so refreshing
repeatedly won't spam. All inputs reuse the existing Radar + Portfolio Health.
No push provider, no broker contact.
"""

from __future__ import annotations

from datetime import datetime, timezone
from threading import Lock
from typing import Dict, List, Optional, Protocol

from .models import (
    Notification,
    TYPE_AUTO_WATCHLIST_READY,
    TYPE_BEST_MARKET,
    TYPE_DAILY_PICK,
    TYPE_ELITE_OPPORTUNITY,
    TYPE_MULTIBAGGER,
    TYPE_PORTFOLIO_WARNING,
    TYPE_REBALANCE_REQUIRED,
    TYPE_ROTATION_CHANGED,
)
from .store import NotificationStore

ELITE_SCORE = 90.0
HEALTH_DROP_WARN = 15.0


class RadarLike(Protocol):
    def opportunities(self): ...
    def daily(self): ...


class HealthLike(Protocol):
    def health(self, user_id: int): ...


class AutoWatchlistLike(Protocol):
    def suggestions(self, user_id: int, existing=None): ...


class RebalanceLike(Protocol):
    def rebalance(self, user_id: int, profile=None): ...


class RotationLike(Protocol):
    def global_rotation(self): ...


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _session_date() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


class NotificationService:
    def __init__(
        self,
        store: NotificationStore,
        radar_service: Optional[RadarLike] = None,
        health_service: Optional[HealthLike] = None,
        auto_watchlist_service: Optional[AutoWatchlistLike] = None,
        rebalance_service: Optional[RebalanceLike] = None,
        rotation_service: Optional[RotationLike] = None,
    ):
        self._store = store
        self._radar = radar_service
        self._health = health_service
        self._auto_watchlist = auto_watchlist_service
        self._rebalance = rebalance_service
        self._rotation = rotation_service
        # Last-seen health score per user (for the drop-detection condition).
        self._last_health: Dict[int, float] = {}
        # Last-seen best market (global), for rotation-change detection.
        self._last_best_market: Optional[str] = None
        self._lock = Lock()

    # -- generation ------------------------------------------------------
    def refresh(self, user_id: int) -> int:
        """Evaluate current signals and create any new notifications.

        Returns the number of *new* notifications created. Best-effort: any
        single signal failure is swallowed so the feed still returns.
        """
        created = 0
        day = _session_date()
        created += self._refresh_radar(user_id, day)
        created += self._refresh_health(user_id, day)
        created += self._refresh_auto_watchlist(user_id, day)
        created += self._refresh_rebalance(user_id, day)
        created += self._refresh_rotation(user_id, day)
        return created

    def _refresh_radar(self, user_id: int, day: str) -> int:
        if self._radar is None:
            return 0
        created = 0
        # Elite opportunities + multibaggers + daily picks.
        try:
            opps = self._radar.opportunities()
        except Exception:  # noqa: BLE001
            opps = None
        if opps is not None:
            for o in opps.global_top10:
                if o.score >= ELITE_SCORE:
                    n = self._store.add(
                        Notification(
                            user_id=user_id,
                            notification_type=TYPE_ELITE_OPPORTUNITY,
                            title="New Elite Opportunity",
                            body=(
                                f"{o.symbol} scored {o.score:.0f} "
                                f"({o.market.value}) — {o.recommendation}."
                            ),
                            symbol=o.symbol,
                            market=o.market.value,
                            created_at=_now_iso(),
                        ),
                        dedup_key=f"elite:{day}:{o.market.value}:{o.symbol}",
                    )
                    if n is not None:
                        created += 1
            for o in opps.multibagger_candidates:
                n = self._store.add(
                    Notification(
                        user_id=user_id,
                        notification_type=TYPE_MULTIBAGGER,
                        title="New Multibagger Candidate",
                        body=(
                            f"{o.symbol} ({o.market.value}) qualifies as a "
                            f"multibagger candidate (score {o.score:.0f})."
                        ),
                        symbol=o.symbol,
                        market=o.market.value,
                        created_at=_now_iso(),
                    ),
                    dedup_key=f"mb:{day}:{o.market.value}:{o.symbol}",
                )
                if n is not None:
                    created += 1
        # Daily Pick published (one per session).
        try:
            daily = self._radar.daily()
        except Exception:  # noqa: BLE001
            daily = None
        if daily is not None and daily.picks:
            top = daily.picks[0]
            n = self._store.add(
                Notification(
                    user_id=user_id,
                    notification_type=TYPE_DAILY_PICK,
                    title="Daily Picks Published",
                    body=(
                        "Today's top opportunities are ready. "
                        f"#1: {top.symbol} ({top.market.value}), "
                        f"score {top.score:.0f}."
                    ),
                    symbol=top.symbol,
                    market=top.market.value,
                    created_at=_now_iso(),
                ),
                dedup_key=f"daily:{daily.date or day}",
            )
            if n is not None:
                created += 1
        return created

    def _refresh_health(self, user_id: int, day: str) -> int:
        if self._health is None:
            return 0
        try:
            health = self._health.health(user_id)
        except Exception:  # noqa: BLE001
            return 0
        score = float(health.health_score)
        with self._lock:
            prev = self._last_health.get(user_id)
            self._last_health[user_id] = score
        if prev is None:
            return 0
        drop = prev - score
        if drop <= HEALTH_DROP_WARN:
            return 0
        n = self._store.add(
            Notification(
                user_id=user_id,
                notification_type=TYPE_PORTFOLIO_WARNING,
                title="Portfolio Health Warning",
                body=(
                    f"Your portfolio health dropped from {prev:.0f} to "
                    f"{score:.0f}. Review your holdings."
                ),
                created_at=_now_iso(),
            ),
            # Dedup per (day, rounded previous->current) so each distinct drop
            # notifies once.
            dedup_key=f"health:{day}:{prev:.0f}->{score:.0f}",
        )
        return 1 if n is not None else 0

    # -- Phase 3 generators ---------------------------------------------
    def _refresh_auto_watchlist(self, user_id: int, day: str) -> int:
        if self._auto_watchlist is None:
            return 0
        try:
            resp = self._auto_watchlist.suggestions(user_id)
        except Exception:  # noqa: BLE001
            return 0
        sugg = getattr(resp, "suggestions", []) or []
        if not sugg:
            return 0
        top = sugg[0]
        n = self._store.add(
            Notification(
                user_id=user_id,
                notification_type=TYPE_AUTO_WATCHLIST_READY,
                title="Auto Watchlist Suggestion Ready",
                body=(
                    f"{len(sugg)} new pick(s) ready to add. Top: "
                    f"{top.symbol} ({top.market.value}), score "
                    f"{top.score:.0f}."
                ),
                symbol=top.symbol,
                market=top.market.value,
                created_at=_now_iso(),
            ),
            dedup_key=f"awl:{day}:{len(sugg)}:{top.symbol}",
        )
        return 1 if n is not None else 0

    def _refresh_rebalance(self, user_id: int, day: str) -> int:
        if self._rebalance is None:
            return 0
        try:
            resp = self._rebalance.rebalance(user_id)
        except Exception:  # noqa: BLE001
            return 0
        high = int(getattr(resp, "high_priority_count", 0) or 0)
        if high <= 0:
            return 0
        n = self._store.add(
            Notification(
                user_id=user_id,
                notification_type=TYPE_REBALANCE_REQUIRED,
                title="Rebalance Action Required",
                body=(
                    f"{high} high-priority rebalancing action(s) recommended "
                    "for your simulated portfolio."
                ),
                created_at=_now_iso(),
            ),
            dedup_key=f"rebal:{day}:{high}",
        )
        return 1 if n is not None else 0

    def _refresh_rotation(self, user_id: int, day: str) -> int:
        if self._rotation is None:
            return 0
        try:
            resp = self._rotation.global_rotation()
        except Exception:  # noqa: BLE001
            return 0
        best = getattr(resp, "best_market", "") or ""
        if not best:
            return 0
        with self._lock:
            prev = self._last_best_market
            self._last_best_market = best
        created = 0
        # New Best Market Today: announce the current leader once per session.
        n = self._store.add(
            Notification(
                user_id=user_id,
                notification_type=TYPE_BEST_MARKET,
                title="New Best Market Today",
                body=(
                    f"{best} has the strongest opportunity environment today."
                ),
                market=best,
                created_at=_now_iso(),
            ),
            dedup_key=f"bestmkt:{day}:{best}",
        )
        if n is not None:
            created += 1
        # Global Rotation Changed: only when the leader changed vs last seen.
        if prev is not None and prev != best:
            n2 = self._store.add(
                Notification(
                    user_id=user_id,
                    notification_type=TYPE_ROTATION_CHANGED,
                    title="Global Rotation Changed",
                    body=(
                        f"Best market rotated from {prev} to {best}."
                    ),
                    market=best,
                    created_at=_now_iso(),
                ),
                dedup_key=f"rotchg:{day}:{prev}->{best}",
            )
            if n2 is not None:
                created += 1
        return created

    # -- test/seed hook --------------------------------------------------
    def set_last_health(self, user_id: int, score: float) -> None:
        """Seed the last-seen health score (used to detect the next drop)."""
        with self._lock:
            self._last_health[user_id] = score

    def set_last_best_market(self, market: Optional[str]) -> None:
        """Seed the last-seen best market (used to detect a rotation change)."""
        with self._lock:
            self._last_best_market = market

    # -- reads -----------------------------------------------------------
    def list(self, user_id: int, *, refresh: bool = True):
        if refresh:
            self.refresh(user_id)
        notifications = self._store.list_for(user_id)
        unread = sum(1 for n in notifications if not n.read)
        return notifications, unread

    def mark_read(self, user_id: int, ids: Optional[List[int]] = None) -> int:
        return self._store.mark_read(user_id, ids)

    def unread_count(self, user_id: int) -> int:
        return self._store.unread_count(user_id)
