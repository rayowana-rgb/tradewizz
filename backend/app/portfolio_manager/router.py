"""FastAPI router for /v1/portfolio/manager — the AI Portfolio Manager.

Open to all during the preview phase (no hard gate). Each view records a
`portfolio_manager_opened` demand event. Reads SIMULATED data only — no broker
contact, no real-money trading.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import (
    EVENT_PORTFOLIO_MANAGER_OPENED,
    METRIC_PORTFOLIO,
)
from .models import PortfolioManagerReport
from .service import PortfolioManagerService

router = APIRouter(prefix="/v1/portfolio", tags=["portfolio-manager"])

_service: Optional[PortfolioManagerService] = None


def set_service(service: PortfolioManagerService) -> None:
    global _service
    _service = service


def get_service() -> PortfolioManagerService:
    if _service is None:
        raise HTTPException(
            status_code=503, detail="Portfolio manager not ready."
        )
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/manager", response_model=PortfolioManagerReport)
def portfolio_manager(
    authorization: Optional[str] = Header(default=None),
) -> PortfolioManagerReport:
    """AI Portfolio Manager (open to all during the preview phase)."""
    uid = _user_id(authorization)
    sub = get_sub_service()
    sub.record_usage(uid, METRIC_PORTFOLIO, meta="manager")
    # OWNER with the Moomoo bridge configured -> advise over the REAL live book
    # (same engine); everyone else stays on the simulation. Fall back to the
    # simulation if the live book is momentarily unavailable.
    from ..moomoo.router import owner_live_analytics
    analytics = owner_live_analytics(uid)
    report = None
    if analytics is not None:
        try:
            report = analytics.manager()
        except Exception:
            report = None
    if report is None:
        report = get_service().report(uid)
    # portfolio_manager_opened: user_id, risk_level.
    sub.record_preview_event(
        uid, EVENT_PORTFOLIO_MANAGER_OPENED, meta=report.risk_level
    )
    return report
