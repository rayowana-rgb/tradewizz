"""FastAPI router for /v1/rotation/global — Global Rotation Engine.

  * GET /v1/rotation/global -> ranked markets + best market + recommendations.

Demand event: global_rotation_opened. Research only — no broker contact.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import EVENT_GLOBAL_ROTATION_OPENED
from .models import GlobalRotationResponse
from .service import GlobalRotationService

router = APIRouter(prefix="/v1/rotation", tags=["rotation"])

_service: Optional[GlobalRotationService] = None


def set_service(service: GlobalRotationService) -> None:
    global _service
    _service = service


def get_service() -> GlobalRotationService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Rotation not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/global", response_model=GlobalRotationResponse)
def global_rotation(
    authorization: Optional[str] = Header(default=None),
) -> GlobalRotationResponse:
    """Rank all supported markets by opportunity environment."""
    uid = _user_id(authorization)
    get_sub_service().record_preview_event(uid, EVENT_GLOBAL_ROTATION_OPENED)
    return get_service().global_rotation()
