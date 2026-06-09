"""Subscription service: tier state, gating, limits, and usage analytics.

This is the single gate other modules ask: "may this user use feature X?" and
"has this user hit their daily limit for metric Y?". It also records analytics
events (Phase 9). Billing is a placeholder — `upgrade()` simply sets the tier
(an app-store receipt would be validated here later).
"""

from __future__ import annotations

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
    ):
        self._store = store or SqliteSubscriptionStore()
        self._clock = clock

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
        """Raise 402 (Payment Required) if the user can't access ``feature``."""
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
        """Clamp a requested screener limit to the tier's max (FREE = 20)."""
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

    def check_and_count_analysis(self, user_id: int) -> int:
        """Enforce the daily-analysis limit, then record one use.

        Returns the new count. Raises 402 when a FREE user is over the cap.
        """
        limit = limits_for(self.current_tier(user_id)).analysis_per_day
        used = self._store.usage_today(user_id, METRIC_ANALYSIS)
        if limit != UNLIMITED and used >= limit:
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
        return EntitlementResponse(
            user_id=user_id,
            tier=row.tier,
            active=row.active,
            expires_at=row.expires_at,
            limits=TierLimitsModel(
                watchlist_max=tier.limits.watchlist_max,
                analysis_per_day=tier.limits.analysis_per_day,
                screener_max_results=tier.limits.screener_max_results,
            ),
            features=list(tier.features),
            usage=UsageToday(
                analysis_count=analysis_used,
                analysis_limit=analysis_limit,
                analysis_remaining=remaining,
            ),
        )

    def plans(self) -> dict:
        return feature_matrix()
