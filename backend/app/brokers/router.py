"""FastAPI router for /v1/brokers (per-user broker connections).

All endpoints require a valid Bearer JWT (the user owns their connections).
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Header, HTTPException

from ..auth.router import get_service as get_auth_service
from ..auth.service import AuthError
from ..broker.models import (
    BrokerStatus,
    OrderPreview,
    OrderRequest,
    OrderResult,
    PlaceOrderRequest,
)
from .ibkr_client import IBKRError
from .ibkr_service import IBKROrderValidationError, IBKRService
from .models import (
    BrokerConnection,
    BrokerConnectionList,
    ConnectBrokerRequest,
    DisconnectResult,
)
from .service import BrokerConnectionService, ConnectionError_

router = APIRouter(prefix="/v1/brokers", tags=["brokers"])

_service = BrokerConnectionService()
# IBKR order service (paper by default). Tests override via set_ibkr_service.
_ibkr_service = IBKRService()


def get_service() -> BrokerConnectionService:
    return _service


def set_service(service: BrokerConnectionService) -> None:
    global _service
    _service = service


def get_ibkr_service() -> IBKRService:
    return _ibkr_service


def set_ibkr_service(service: IBKRService) -> None:
    global _ibkr_service
    _ibkr_service = service


def _user_id(authorization: Optional[str]) -> int:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token.")
    token = authorization.split(" ", 1)[1].strip()
    try:
        return get_auth_service().verify_token(token)
    except AuthError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.get("", response_model=BrokerConnectionList)
def list_brokers(
    authorization: Optional[str] = Header(default=None),
) -> BrokerConnectionList:
    uid = _user_id(authorization)
    return BrokerConnectionList(connections=get_service().list(uid))


@router.post("/connect", response_model=BrokerConnection)
def connect_broker(
    req: ConnectBrokerRequest,
    authorization: Optional[str] = Header(default=None),
) -> BrokerConnection:
    uid = _user_id(authorization)
    try:
        return get_service().connect(uid, req.broker_type, req.display_name)
    except ConnectionError_ as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


# --------------------------------------------------------------------------- #
# IBKR order flow (per-user, authenticated). Mirrors the Moomoo safety model:  #
# preview never places; place requires the confirmation token from preview.    #
# Read-Only API mode, insufficient funds and invalid symbol all return a clear #
# error message (never a generic 'order failed').                              #
# --------------------------------------------------------------------------- #
@router.get("/ibkr/status", response_model=BrokerStatus)
def ibkr_status(
    authorization: Optional[str] = Header(default=None),
) -> BrokerStatus:
    _user_id(authorization)
    return get_ibkr_service().status()


@router.post("/ibkr/order/preview", response_model=OrderPreview)
def ibkr_order_preview(
    req: OrderRequest,
    authorization: Optional[str] = Header(default=None),
) -> OrderPreview:
    uid = _user_id(authorization)
    try:
        return get_ibkr_service().preview(
            req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price, user_id=uid,
        )
    except IBKROrderValidationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)


@router.post("/ibkr/order/place", response_model=OrderResult)
def ibkr_order_place(
    req: PlaceOrderRequest,
    authorization: Optional[str] = Header(default=None),
) -> OrderResult:
    uid = _user_id(authorization)
    try:
        return get_ibkr_service().place(
            req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price, req.confirmation_token, user_id=uid,
        )
    except IBKROrderValidationError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    except IBKRError as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@router.delete("/{conn_id}", response_model=DisconnectResult)
def disconnect_broker(
    conn_id: int,
    authorization: Optional[str] = Header(default=None),
) -> DisconnectResult:
    uid = _user_id(authorization)
    try:
        return get_service().disconnect(uid, conn_id)
    except ConnectionError_ as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
