"""FastAPI router for /v1/broker/moomoo/* — PRIVATE live trading bridge.

Access control (defence in depth):
  1. Bearer JWT whose user id is in the owner allowlist (env
     TRADEWIZZ_MOOMOO_OWNER_UIDS, default "2").
  2. A shared secret header  X-Moomoo-Secret  matching env
     TRADEWIZZ_MOOMOO_SECRET. If that env var is UNSET, the whole router is
     hard-disabled (returns 404-like 503) so it can never be reached by
     accident in the public deployment.

This router is intentionally NOT part of the public product surface.
"""

from __future__ import annotations

import logging
import os
from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from .models import (
    MoomooAccountModel,
    MoomooCancelResult,
    MoomooOrderPreview,
    MoomooOrderRequest,
    MoomooOrderResultModel,
    MoomooPositionList,
    MoomooPositionModel,
)
from .service import MoomooError, MoomooService

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/broker/moomoo", tags=["moomoo-private"])

_service: Optional[MoomooService] = None


def set_service(service: MoomooService) -> None:
    global _service
    _service = service


def get_service() -> MoomooService:
    global _service
    if _service is None:
        _service = MoomooService()
    return _service


def _owner_uids() -> set[int]:
    raw = os.environ.get("TRADEWIZZ_MOOMOO_OWNER_UIDS", "2")
    out: set[int] = set()
    for part in raw.split(","):
        part = part.strip()
        if part.isdigit():
            out.add(int(part))
    return out


def _require_owner(authorization: Optional[str], secret: Optional[str]) -> int:
    configured = os.environ.get("TRADEWIZZ_MOOMOO_SECRET", "")
    if not configured:
        # Hard-disabled unless explicitly configured.
        raise HTTPException(status_code=503, detail="Moomoo bridge disabled.")
    if not secret or secret != configured:
        raise HTTPException(status_code=403, detail="Forbidden.")
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        uid = get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    if int(uid) not in _owner_uids():
        raise HTTPException(status_code=403, detail="Not an owner account.")
    return int(uid)


def _handle(exc: MoomooError) -> HTTPException:
    return HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("/account", response_model=MoomooAccountModel)
def moomoo_account(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooAccountModel:
    _require_owner(authorization, x_moomoo_secret)
    try:
        a = get_service().account()
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooAccountModel(
        total_assets=a.total_assets, cash=a.cash, buying_power=a.buying_power,
        market_value=a.market_value, currency=a.currency,
    )


@router.get("/positions", response_model=MoomooPositionList)
def moomoo_positions(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooPositionList:
    _require_owner(authorization, x_moomoo_secret)
    try:
        ps = get_service().positions()
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooPositionList(
        positions=[
            MoomooPositionModel(
                code=p.code, symbol=p.symbol, quantity=p.qty,
                can_sell_qty=p.can_sell_qty, cost_price=p.cost_price,
                last_price=p.last_price, pl_val=p.pl_val, pl_ratio=p.pl_ratio,
            )
            for p in ps
        ]
    )


@router.post("/order/preview", response_model=MoomooOrderPreview)
def moomoo_preview(
    req: MoomooOrderRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooOrderPreview:
    _require_owner(authorization, x_moomoo_secret)
    try:
        pv = get_service().preview(
            req.symbol, req.side, req.quantity, req.order_type, req.price
        )
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooOrderPreview(**pv)


@router.post("/order/place", response_model=MoomooOrderResultModel)
def moomoo_place(
    req: MoomooOrderRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooOrderResultModel:
    uid = _require_owner(authorization, x_moomoo_secret)
    try:
        r = get_service().place(
            req.symbol, req.side, req.quantity, req.order_type, req.price,
            req.confirm, trade_pin=req.trade_pin,
        )
    except MoomooError as exc:
        raise _handle(exc)
    logger.warning(
        "MOOMOO LIVE ORDER placed by uid=%s: %s %s %s %s",
        uid, r.side, r.qty, r.code, r.order_id,
    )
    return MoomooOrderResultModel(
        order_id=r.order_id, code=r.code, side=r.side, order_type=r.order_type,
        quantity=r.qty, price=r.price, status=r.status, live=True,
    )


@router.post("/order/cancel/{order_id}", response_model=MoomooCancelResult)
def moomoo_cancel(
    order_id: str,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooCancelResult:
    _require_owner(authorization, x_moomoo_secret)
    try:
        out = get_service().cancel(order_id)
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooCancelResult(**out)
