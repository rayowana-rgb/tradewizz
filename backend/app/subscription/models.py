"""Pydantic models for the subscription API."""

from __future__ import annotations

from typing import Dict, List, Optional

from pydantic import BaseModel


class UserSubscription(BaseModel):
    """A user's current subscription record."""

    user_id: int
    tier: str = "FREE"
    started_at: str = ""        # ISO-8601
    expires_at: Optional[str] = None  # ISO-8601; None => no expiry (e.g. FREE)
    active: bool = True
    created_at: str = ""
    updated_at: str = ""


class TierLimitsModel(BaseModel):
    watchlist_max: int
    analysis_per_day: int
    screener_max_results: int


class UsageToday(BaseModel):
    """The portion of today's usage that maps to a hard limit."""

    analysis_count: int = 0
    analysis_limit: int = 0       # -1 => unlimited
    analysis_remaining: int = -1  # -1 => unlimited


class EntitlementResponse(BaseModel):
    """Everything the app needs to render gating + the current usage state."""

    user_id: int
    tier: str
    active: bool
    expires_at: Optional[str] = None
    limits: TierLimitsModel
    features: List[str]
    usage: UsageToday


class UpgradeRequest(BaseModel):
    tier: str
    # Placeholder for a future billing token (app-store receipt, etc.). Unused
    # by the simulated upgrade; accepted so the contract is stable.
    receipt: Optional[str] = None


class PlanComparison(BaseModel):
    tiers: List[Dict]
    features: List[Dict]
