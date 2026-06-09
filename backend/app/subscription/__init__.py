"""Subscription / monetization package.

FREE / PRO / ELITE tiers with a per-user subscription record, an entitlement
matrix (what each tier may do + numeric limits), a SQLite-backed store, a
service that the API and other modules query for gating, and the /v1/subscription
router.

This package adds monetization only. It NEVER adds broker integration or
real-money trading; TradeWizz stays a research / AI-analysis / simulation
platform.
"""

from .entitlements import (
    TIERS,
    Tier,
    TierLimits,
    feature_matrix,
    limits_for,
    tier_includes,
)
from .models import UserSubscription
from .service import SubscriptionError, SubscriptionService
from .store import SqliteSubscriptionStore, SubscriptionStore

__all__ = [
    "TIERS",
    "Tier",
    "TierLimits",
    "feature_matrix",
    "limits_for",
    "tier_includes",
    "UserSubscription",
    "SubscriptionError",
    "SubscriptionService",
    "SqliteSubscriptionStore",
    "SubscriptionStore",
]
