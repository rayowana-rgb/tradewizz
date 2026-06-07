"""FastAPI router for /v1/auth endpoints."""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from .models import (
    AuthResponse,
    LoginRequest,
    LogoutResponse,
    RegisterRequest,
    SocialAuthRequest,
    UserProfile,
)
from .service import AuthError, AuthService

router = APIRouter(prefix="/v1/auth", tags=["auth"])

_service = AuthService()


def get_service() -> AuthService:
    return _service


def set_service(service: AuthService) -> None:
    """Swap the active service (tests inject an in-memory-store service)."""
    global _service
    _service = service


def _bearer(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    return authorization.split(" ", 1)[1].strip()


@router.post("/register", response_model=AuthResponse)
def register(req: RegisterRequest) -> AuthResponse:
    try:
        return get_service().register(req.email, req.password)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/login", response_model=AuthResponse)
def login(req: LoginRequest) -> AuthResponse:
    try:
        return get_service().login(req.email, req.password)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/google", response_model=AuthResponse)
def google_login(req: SocialAuthRequest) -> AuthResponse:
    """Sign in / register with a Google ID token. Returns a TradeWizz JWT."""
    try:
        return get_service().google_login(req.id_token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/apple", response_model=AuthResponse)
def apple_login(req: SocialAuthRequest) -> AuthResponse:
    """Sign in / register with an Apple identity token. Returns a TradeWizz JWT."""
    try:
        return get_service().apple_login(req.id_token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/me", response_model=UserProfile)
def me(authorization: Optional[str] = Header(default=None)) -> UserProfile:
    token = _bearer(authorization)
    try:
        return get_service().me(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/logout", response_model=LogoutResponse)
def logout(authorization: Optional[str] = Header(default=None)) -> LogoutResponse:
    # Stateless JWT: logout is client-side (drop the token). Validate if present
    # so a clearly-invalid token still returns a clean 200 logout.
    return LogoutResponse(success=True, message="Logged out.")
