"""Subscription service: tier state, gating, limits, and usage analytics.

This is the single gate other modules ask: "may this user use feature X?" and
"has this user hit their daily limit for metric Y?". It also records analytics
events (Phase 9). Billing is a placeholder — `upgrade()` simply sets the tier
(an app-store receipt would be validated here later).
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta, timezone
from typing import Optional

from .entitlements import (
    ELITE,
    FREE,
    PRO,
    TIERS,
    UNLIMITED,
    feature_matrix,
    limits_for,
    normalize_tier,
    tier_includes,
)
from .models import (
    EntitlementResponse,
    TierLimitsModel,
    UsageToday,
    UserSubscription,
)
from .store import (
    SqliteSubscriptionStore,
    SubscriptionRow,
    SubscriptionStore,
)

# Analytics metric names (Phase 9). Also used as daily-limit keys.
METRIC_ANALYSIS = "analysis"
METRIC_RADAR_VIEW = "radar_view"
METRIC_WATCHLIST = "watchlist_usage"
METRIC_PORTFOLIO = "portfolio_usage"

# --- Preview-feature analytics events (PRO/ELITE Preview pivot) -------------
# During the preview phase nothing is enforced; we ONLY measure demand. These
# are the exact event names requested by product, recorded verbatim.
EVENT_RADAR_OPENED = "radar_opened"
EVENT_DAILY_PICKS_OPENED = "daily_picks_opened"
EVENT_PORTFOLIO_HEALTH_OPENED = "portfolio_health_opened"
EVENT_PORTFOLIO_QUALITY_OPENED = "portfolio_quality_opened"
EVENT_MULTIBAGGER_OPENED = "multibagger_opened"
EVENT_AI_PORTFOLIO_MANAGER_OPENED = "ai_portfolio_manager_opened"
EVENT_WAITLIST_JOINED = "waitlist_joined"
# Phase 2 (retention) preview-demand events, recorded verbatim.
EVENT_MORNING_BRIEF_OPENED = "morning_brief_opened"
EVENT_NOTIFICATION_OPENED = "notification_opened"
EVENT_PORTFOLIO_MANAGER_OPENED = "portfolio_manager_opened"
EVENT_JOURNAL_OPENED = "journal_opened"


def _preview_mode_default() -> bool:
    """Preview mode is ON by default (PRO/ELITE Preview pivot).

    Set TRADEWIZZ_PREVIEW_MODE=0/false to re-arm hard enforcement (the paywall
    infrastructure is kept fully intact, just dormant).
    """
    raw = os.environ.get("TRADEWIZZ_PREVIEW_MODE")
    if raw is None:
        return True
    return raw.strip().lower() not in ("0", "false", "no", "off")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.isoformat()


class SubscriptionError(Exception):
    """Gating / validation failure mapped to an HTTP error by the router."""

    def __init__(self, message: str, status_code: int = 400, **extra):
        super().__init__(message)
        self.message = message
        self.status_code = status_code
        self.extra = extra


class SubscriptionService:
    def __init__(
        self,
        store: Optional[SubscriptionStore] = None,
        clock=_now,
        preview_mode: Optional[bool] = None,
    ):
        self._store = store or SqliteSubscriptionStore()
        self._clock = clock
        # Preview phase: features are open to everyone, limits are not enforced,
        # and we only collect demand analytics. The paywall infra stays intact.
        self._preview_mode = (
            _preview_mode_default() if preview_mode is None else preview_mode
        )

    @property
    def preview_mode(self) -> bool:
        return self._preview_mode

    # -- subscription state ---------------------------------------------
    def _ensure(self, user_id: int) -> SubscriptionRow:
        """Return the user's subscription, creating a FREE one on first touch.

        Also auto-expires a paid tier whose ``expires_at`` has passed: the row
        is downgraded to FREE (active stays true for FREE).
        """
        row = self._store.get(user_id)
        now = self._clock()
        if row is None:
            now_iso = _iso(now)
            row = SubscriptionRow(
                user_id=user_id,
                tier=FREE,
                started_at=now_iso,
                expires_at=None,
                active=True,
                created_at=now_iso,
                updated_at=now_iso,
            )
            return self._store.upsert(row)

        # Auto-expire paid tiers.
        if row.tier != FREE and row.expires_at:
            try:
                exp = datetime.fromisoformat(row.expires_at)
                if exp <= now:
                    row = SubscriptionRow(
                        user_id=user_id,
                        tier=FREE,
                        started_at=_iso(now),
                        expires_at=None,
                        active=True,
                        created_at=row.created_at,
                        updated_at=_iso(now),
                    )
                    row = self._store.upsert(row)
            except ValueError:
                pass
        return row

    def get_subscription(self, user_id: int) -> UserSubscription:
        row = self._ensure(user_id)
        return UserSubscription(
            user_id=row.user_id,
            tier=row.tier,
            started_at=row.started_at,
            expires_at=row.expires_at,
            active=row.active,
            created_at=row.created_at,
            updated_at=row.updated_at,
        )

    def current_tier(self, user_id: int) -> str:
        return self._ensure(user_id).tier

    def upgrade(
        self,
        user_id: int,
        tier: str,
        months: int = 1,
        receipt: Optional[str] = None,
    ) -> UserSubscription:
        """Set the user's tier (placeholder billing).

        A real implementation would validate ``receipt`` with the app store.
        Here we just activate the requested tier for ``months`` (FREE clears
        any expiry / downgrades).
        """
        target = normalize_tier(tier)
        if target not in TIERS:
            raise SubscriptionError(f"Unknown tier '{tier}'.", status_code=400)
        now = self._clock()
        existing = self._ensure(user_id)
        if target == FREE:
            expires_at = None
        else:
            expires_at = _iso(now + timedelta(days=30 * max(1, months)))
        row = SubscriptionRow(
            user_id=user_id,
            tier=target,
            started_at=_iso(now),
            expires_at=expires_at,
            active=True,
            created_at=existing.created_at,
            updated_at=_iso(now),
        )
        self._store.upsert(row)
        return self.get_subscription(user_id)

    # -- entitlement / gating -------------------------------------------
    def has_feature(self, user_id: int, feature: str) -> bool:
        return tier_includes(self.current_tier(user_id), feature)

    def require_feature(self, user_id: int, feature: str) -> None:
        """Raise 402 (Payment Required) if the user can't access ``feature``.

        PREVIEW MODE: never raises — every user may open every feature. The
        paywall remains dormant (re-armed by TRADEWIZZ_PREVIEW_MODE=0).
        """
        if self._preview_mode:
            return
        tier = self.current_tier(user_id)
        if not tier_includes(tier, feature):
            from .entitlements import min_tier_for

            need = min_tier_for(feature)
            raise SubscriptionError(
                f"This feature requires the {need} plan. "
                f"Upgrade to {need} to unlock it.",
                status_code=402,
                required_tier=need,
                feature=feature,
                current_tier=tier,
            )

    def cap_screener_limit(self, user_id: int, requested: int) -> int:
        """Clamp a requested screener limit to the tier's max (FREE = 20).

        PREVIEW MODE: no cap — the requested limit is returned unchanged.
        """
        if self._preview_mode:
            return requested
        cap = limits_for(self.current_tier(user_id)).screener_max_results
        if cap == UNLIMITED:
            return requested
        return min(requested, cap)

    def watchlist_limit(self, user_id: int) -> int:
        return limits_for(self.current_tier(user_id)).watchlist_max

    # -- usage / analytics ----------------------------------------------
    def record_usage(
        self, user_id: int, metric: str, count: int = 1, meta: str = ""
    ) -> None:
        self._store.record_event(user_id, metric, count=count, meta=meta)

    def record_preview_event(
        self, user_id: int, event: str, meta: str = "", count: int = 1
    ) -> None:
        """Record a preview-feature usage event (demand analytics only).

        ``meta`` carries the requested per-event fields (e.g. market, symbol,
        portfolio_score) as a short string so we can break demand down later.
        """
        self._store.record_event(user_id, event, count=count, meta=meta)

    def join_waitlist(self, user_id: int, tier: str) -> dict:
        """Record an early-access waiting-list join (no payment, ever)."""
        target = normalize_tier(tier)
        self._store.record_event(
            user_id, EVENT_WAITLIST_JOINED, count=1, meta=target
        )
        return {
            "user_id": user_id,
            "tier": target,
            "status": "waitlisted",
            "preview": True,
            "message": (
                "TradeWizz "
                f"{target} is currently in preview. You have been added to "
                "the early-access waiting list."
            ),
        }

    def check_and_count_analysis(self, user_id: int) -> int:
        """Enforce the daily-analysis limit, then record one use.

        Returns the new count. Raises 402 when a FREE user is over the cap.
        PREVIEW MODE: the limit is NOT enforced; the use is still recorded so
        we keep measuring demand.
        """
        limit = limits_for(self.current_tier(user_id)).analysis_per_day
        used = self._store.usage_today(user_id, METRIC_ANALYSIS)
        if not self._preview_mode and limit != UNLIMITED and used >= limit:
            raise SubscriptionError(
                f"Daily analysis limit reached ({limit}/day on your plan). "
                "Upgrade to Pro for unlimited analysis.",
                status_code=402,
                required_tier=PRO,
                feature="analysis",
                limit=limit,
                used=used,
            )
        self._store.record_event(user_id, METRIC_ANALYSIS, count=1)
        return used + 1

    def usage_summary(self, user_id: int) -> dict:
        return self._store.usage_summary(user_id)

    def demand_breakdown(self, metric: Optional[str] = None) -> list:
        """Cross-user feature-demand analytics for the preview phase."""
        return self._store.event_breakdown(metric)

    # -- response builders ----------------------------------------------
    def entitlements(self, user_id: int) -> EntitlementResponse:
        row = self._ensure(user_id)
        tier = TIERS[normalize_tier(row.tier)]
        analysis_used = self._store.usage_today(user_id, METRIC_ANALYSIS)
        analysis_limit = tier.limits.analysis_per_day
        remaining = (
            UNLIMITED
            if analysis_limit == UNLIMITED
            else max(0, analysis_limit - analysis_used)
        )
        # In preview mode every feature is unlocked, so the app receives the
        # full feature list (everyone is effectively "all features"), but we
        # also tell it which ones to badge as PRO/ELITE PREVIEW.
        if self._preview_mode:
            effective_features = list(TIERS[ELITE].features)
            preview_features = [
                f for f in TIERS[ELITE].features
                if f not in TIERS[FREE].features
            ]
            unlimited_limits = TierLimitsModel(
                watchlist_max=UNLIMITED,
                analysis_per_day=UNLIMITED,
                screener_max_results=UNLIMITED,
            )
        else:
            effective_features = list(tier.features)
            preview_features = []
            unlimited_limits = TierLimitsModel(
                watchlist_max=tier.limits.watchlist_max,
                analysis_per_day=tier.limits.analysis_per_day,
                screener_max_results=tier.limits.screener_max_results,
            )
        return EntitlementResponse(
            user_id=user_id,
            tier=row.tier,
            active=row.active,
            expires_at=row.expires_at,
            limits=unlimited_limits,
            features=effective_features,
            usage=UsageToday(
                analysis_count=analysis_used,
                analysis_limit=(
                    UNLIMITED if self._preview_mode else analysis_limit
                ),
                analysis_remaining=(
                    UNLIMITED if self._preview_mode else remaining
                ),
            ),
            preview=self._preview_mode,
            preview_features=preview_features,
        )

    def plans(self) -> dict:
        matrix = feature_matrix()
        matrix["preview"] = self._preview_mode
        return matrix
