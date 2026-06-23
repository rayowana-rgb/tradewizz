"""FastAPI router for /v1/sim/* — the simulated paper-trading portfolio.

Every endpoint requires a Bearer JWT (the user owns their simulated portfolio).
NO endpoint here ever contacts a broker. All responses carry ``simulated=true``.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

from fastapi import APIRouter, Header, HTTPException

logger = logging.getLogger(__name__)

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from .models import (
    SimulatedAccount,
    SimulatedCancelResult,
    SimulatedOrderPreview,
    SimulatedOrderRequest,
    SimulatedOrderResult,
    SimulatedPendingOrderList,
    SimulatedPortfolioSummary,
    SimulatedPositionList,
    SimulatedResetResult,
    SimulatedTradeList,
)
from .service import SimulationError, SimulationService

router = APIRouter(prefix="/v1/sim", tags=["simulation"])

# Injected at startup by main.py (shares the app's engine for price lookup).
_service: Optional[SimulationService] = None


# Optional best-effort hook invoked AFTER a simulated order is filled. Used by
# the Portfolio Journal to snapshot buys / close sells. It NEVER affects the
# simulation accounting and any failure is swallowed.
_trade_hook: Optional[Callable[..., None]] = None


def set_service(service: SimulationService) -> None:
    global _service
    _service = service


def set_trade_hook(hook: Optional[Callable[..., None]]) -> None:
    global _trade_hook
    _trade_hook = hook


def _dispatch_trade_hook(uid, symbol, market, side, quantity, price) -> None:
    """Fire the trade hook off the request path in a detached daemon thread.

    The hook is purely advisory (journal logging); it must never delay or fail
    the order response. Any exception is logged and swallowed inside the thread.
    """
    hook = _trade_hook
    if hook is None:
        return

    def _run() -> None:
        try:
            hook(uid, symbol, market, side, quantity, price)
        except Exception as exc:  # noqa: BLE001 - never propagate
            logger.warning("trade hook failed for %s/%s: %s", symbol, market, exc)

    threading.Thread(target=_run, name="sim-trade-hook", daemon=True).start()


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
        result = get_service().place(
            uid, req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price,
        )
    except SimulationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    # Best-effort journal hook (after the fill). Run it in a DETACHED daemon
    # thread so it can NEVER block the order response: the hook performs heavy
    # work (single-symbol score screen + daily radar + portfolio health) that
    # may hit a slow/rate-limited data provider and take seconds. Doing it
    # inline made the BUY "confirm" call stall and time out. The journal entry
    # lands a moment after the fill, which is fine for a paper-trade log.
    # Skip the hook for a PENDING (queued, not-yet-filled) order: there is no
    # position to journal until it settles at the open.
    if _trade_hook is not None and not result.pending:
        _dispatch_trade_hook(
            uid, result.symbol, result.market, result.side,
            result.quantity, result.price,
        )
    return result


@router.get("/pending", response_model=SimulatedPendingOrderList)
def sim_pending(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedPendingOrderList:
    uid = _user_id(authorization)
    return SimulatedPendingOrderList(pending=get_service().pending(uid))


@router.post("/order/cancel/{order_id}", response_model=SimulatedCancelResult)
def sim_order_cancel(
    order_id: str,
    authorization: Optional[str] = Header(default=None),
) -> SimulatedCancelResult:
    uid = _user_id(authorization)
    try:
        return get_service().cancel(uid, order_id)
    except SimulationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/reset", response_model=SimulatedResetResult)
def sim_reset(
    authorization: Optional[str] = Header(default=None),
) -> SimulatedResetResult:
    uid = _user_id(authorization)
    acct = get_service().reset(uid)
    return SimulatedResetResult(user_id=uid, cash=acct.cash)
