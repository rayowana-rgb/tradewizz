"""FastAPI router for /v1/sim/* — the simulated paper-trading portfolio.

Every endpoint requires a Bearer JWT (the user owns their simulated portfolio).
NO endpoint here ever contacts a broker. All responses carry ``simulated=true``.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from .models import (
    SimulatedAccount,
    SimulatedOrderPreview,
    SimulatedOrderRequest,
    SimulatedOrderResult,
    SimulatedPortfolioSummary,
    SimulatedPositionList,
    SimulatedResetResult,
    SimulatedTradeList,
)
from .service import SimulationError, SimulationService

router = APIRouter(prefix="/v1/sim", tags=["simulation"])

# Injected at startup by main.py (shares the app's engine for price lookup).
_service: Optional[SimulationService] = None


def set_service(service: SimulationService) -> None:
    global _service
    _service = service


def get_service() -> SimulationService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Simulation not ready.")
    return _service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/account", response_model=SimulatedAccount)
def sim_account(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedAccount:
    return get_service().account(_user_id(authorization))


@router.get("/portfolio", response_model=SimulatedPortfolioSummary)
def sim_portfolio(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedPortfolioSummary:
    return get_service().portfolio(_user_id(authorization))


@router.get("/positions", response_model=SimulatedPositionList)
def sim_positions(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedPositionList:
    uid = _user_id(authorization)
    return SimulatedPositionList(positions=get_service().positions(uid))


@router.get("/trades", response_model=SimulatedTradeList)
def sim_trades(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedTradeList:
    uid = _user_id(authorization)
    return SimulatedTradeList(trades=get_service().trades(uid))


@router.post("/order/preview", response_model=SimulatedOrderPreview)
def sim_order_preview(
    req: SimulatedOrderRequest,
    authorization: Optional[str] = Header(default=None),
) -> SimulatedOrderPreview:
    uid = _user_id(authorization)
    try:
        return get_service().preview(
            uid, req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price,
        )
    except SimulationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/order/place", response_model=SimulatedOrderResult)
def sim_order_place(
    req: SimulatedOrderRequest,
    authorization: Optional[str] = Header(default=None),
) -> SimulatedOrderResult:
    uid = _user_id(authorization)
    try:
        return get_service().place(
            uid, req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price,
        )
    except SimulationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/reset", response_model=SimulatedResetResult)
def sim_reset(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedResetResult:
    uid = _user_id(authorization)
    acct = get_service().reset(uid)
    return SimulatedResetResult(user_id=uid, cash=acct.cash)
