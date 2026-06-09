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
    TYPE_DAILY_PICK,
    TYPE_ELITE_OPPORTUNITY,
    TYPE_MULTIBAGGER,
    TYPE_PORTFOLIO_WARNING,
)
from .store import NotificationStore

ELITE_SCORE = 90.0
HEALTH_DROP_WARN = 15.0


class RadarLike(Protocol):
    def opportunities(self): ...
    def daily(self): ...


class HealthLike(Protocol):
    def health(self, user_id: int): ...


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
    ):
        self._store = store
        self._radar = radar_service
        self._health = health_service
        # Last-seen health score per user (for the drop-detection condition).
        self._last_health: Dict[int, float] = {}
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

    # -- test/seed hook --------------------------------------------------
    def set_last_health(self, user_id: int, score: float) -> None:
        """Seed the last-seen health score (used to detect the next drop)."""
        with self._lock:
            self._last_health[user_id] = score

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
