"""FastAPI router for /v1/notifications — in-app notification center.

  * GET  /v1/notifications        -> list + unread count (auto-refreshes feed)
  * POST /v1/notifications/read   -> mark some/all notifications read

Each list view records a `notification_opened` demand event. No push provider,
no broker contact.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..subscription.router import get_service as get_sub_service
from ..subscription.service import EVENT_NOTIFICATION_OPENED
from .models import (
    MarkReadRequest,
    MarkReadResponse,
    NotificationList,
)
from .service import NotificationService

router = APIRouter(prefix="/v1/notifications", tags=["notifications"])

_service: Optional[NotificationService] = None


def set_service(service: NotificationService) -> None:
    global _service
    _service = service


def get_service() -> NotificationService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Notifications not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("", response_model=NotificationList)
def notifications(
    authorization: Optional[str] = Header(default=None),
) -> NotificationList:
    """List in-app notifications (refreshes the feed from current signals)."""
    uid = _user_id(authorization)
    get_sub_service().record_preview_event(uid, EVENT_NOTIFICATION_OPENED)
    items, unread = get_service().list(uid)
    return NotificationList(notifications=items, unread_count=unread)


@router.post("/read", response_model=MarkReadResponse)
def mark_read(
    req: Optional[MarkReadRequest] = None,
    authorization: Optional[str] = Header(default=None),
) -> MarkReadResponse:
    """Mark notifications read (specific ids, or all when none given)."""
    uid = _user_id(authorization)
    ids = req.ids if req else None
    marked = get_service().mark_read(uid, ids)
    return MarkReadResponse(
        user_id=uid,
        marked=marked,
        unread_count=get_service().unread_count(uid),
    )
