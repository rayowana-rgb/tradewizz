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
from .models import (
    EntitlementResponse,
    PlanComparison,
    UpgradeRequest,
    UserSubscription,
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
