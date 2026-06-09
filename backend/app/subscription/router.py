"""FastAPI router for /v1/subscription/* — tiers, entitlements, upgrade, usage.

Every per-user endpoint requires a Bearer JWT. `/plans` is public (the paywall
comparison table). Billing is a placeholder: `/upgrade` sets the tier without
taking payment (an app-store receipt would be validated in the service later).
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from typing import Optional as _Optional

from .models import (
    EntitlementResponse,
    PlanComparison,
    PreviewEventRequest,
    UpgradeRequest,
    UserSubscription,
    WaitlistRequest,
    WaitlistResponse,
)
from .service import SubscriptionError, SubscriptionService

router = APIRouter(prefix="/v1/subscription", tags=["subscription"])

_service: Optional[SubscriptionService] = None


def set_service(service: SubscriptionService) -> None:
    global _service
    _service = service


def get_service() -> SubscriptionService:
    global _service
    if _service is None:
        _service = SubscriptionService()
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/plans", response_model=PlanComparison)
def plans() -> PlanComparison:
    """Public plan comparison table (FREE / PRO / ELITE) for the paywall."""
    return PlanComparison(**get_service().plans())


@router.get("/me", response_model=UserSubscription)
def my_subscription(
    authorization: Optional[str] = Header(default=None),
) -> UserSubscription:
    return get_service().get_subscription(_user_id(authorization))


@router.get("/entitlements", response_model=EntitlementResponse)
def entitlements(
    authorization: Optional[str] = Header(default=None),
) -> EntitlementResponse:
    """Current tier + limits + today's usage; the app gates its UI from this."""
    return get_service().entitlements(_user_id(authorization))


@router.post("/upgrade", response_model=UserSubscription)
def upgrade(
    req: UpgradeRequest,
    authorization: Optional[str] = Header(default=None),
) -> UserSubscription:
    """Activate a tier (placeholder billing — no real payment is taken)."""
    uid = _user_id(authorization)
    try:
        return get_service().upgrade(uid, req.tier, receipt=req.receipt)
    except SubscriptionError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/usage")
def usage(
    authorization: Optional[str] = Header(default=None),
) -> dict:
    """Lifetime usage analytics for the current user (monetization signals)."""
    uid = _user_id(authorization)
    return {"user_id": uid, "totals": get_service().usage_summary(uid)}


@router.post("/waitlist", response_model=WaitlistResponse)
def join_waitlist(
    req: WaitlistRequest,
    authorization: Optional[str] = Header(default=None),
) -> WaitlistResponse:
    """Join the early-access waiting list for a preview tier.

    No payment, no Stripe, no app-store billing. We only record the intent so
    we can measure demand during the preview phase.
    """
    uid = _user_id(authorization)
    return WaitlistResponse(**get_service().join_waitlist(uid, req.tier))


@router.post("/event")
def record_preview_event(
    req: PreviewEventRequest,
    authorization: Optional[str] = Header(default=None),
) -> dict:
    """Record a client-reported preview-feature usage event (demand only)."""
    uid = _user_id(authorization)
    get_service().record_preview_event(uid, req.event, meta=req.meta)
    return {"user_id": uid, "event": req.event, "recorded": True}


@router.get("/demand")
def demand(
    metric: _Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
) -> dict:
    """Cross-user feature-demand analytics for the preview phase.

    Returns per (event, meta) totals + unique-user counts so we can see which
    preview features are opened most before deciding the final paywall.
    """
    # Requires a valid token (any authenticated user); this is internal signal.
    _user_id(authorization)
    return {"breakdown": get_service().demand_breakdown(metric)}
