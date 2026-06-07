"""FastAPI router for /v1/portfolio (unified, auth-scoped)."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from .models import UnifiedPortfolio
from .service import PortfolioService

router = APIRouter(prefix="/v1/portfolio", tags=["portfolio"])

_service = PortfolioService()


def get_service() -> PortfolioService:
    return _service


def set_service(service: PortfolioService) -> None:
    global _service
    _service = service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("", response_model=UnifiedPortfolio)
def portfolio(
    authorization: Optional[str] = Header(default=None),
) -> UnifiedPortfolio:
    uid = _user_id(authorization)
    return get_service().for_user(uid)
