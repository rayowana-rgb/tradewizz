"""FastAPI router for the broker (Moomoo) endpoints under /v1/broker.

All trading is manual: preview never places, place requires a confirmation
token. Paper by default; real only when TRADEWIZZ_TRADING_ENV=real.
"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException

from .client import BrokerError
from .models import (
    AccountSummary,
    BrokerStatus,
    CancelRequest,
    CancelResult,
    OrderPreview,
    OrderRequest,
    OrderResult,
    OrdersResponse,
    PlaceOrderRequest,
    PositionsResponse,
)
from .service import BrokerService, OrderValidationError

router = APIRouter(prefix="/v1/broker", tags=["broker"])

# Default service (real Moomoo client; degrades to "disconnected" if OpenD is
# down). Tests override `router_service` with a mock-backed service.
_service = BrokerService()


def get_service() -> BrokerService:
    return _service


def set_service(service: BrokerService) -> None:
    """Swap the active service (used by tests to inject a mock client)."""
    global _service
    _service = service


@router.get("/status", response_model=BrokerStatus)
def broker_status() -> BrokerStatus:
    return get_service().status()


@router.get("/account", response_model=AccountSummary)
def broker_account() -> AccountSummary:
    try:
        return get_service().account()
    except BrokerError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/positions", response_model=PositionsResponse)
def broker_positions() -> PositionsResponse:
    try:
        return get_service().positions()
    except BrokerError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.post("/order/preview", response_model=OrderPreview)
def broker_order_preview(req: OrderRequest) -> OrderPreview:
    try:
        return get_service().preview(
            req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price,
        )
    except OrderValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.post("/order/place", response_model=OrderResult)
def broker_order_place(req: PlaceOrderRequest) -> OrderResult:
    try:
        return get_service().place(
            req.symbol, req.market, req.side, req.quantity,
            req.order_type, req.price, req.confirmation_token,
        )
    except OrderValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except BrokerError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.get("/orders", response_model=OrdersResponse)
def broker_orders() -> OrdersResponse:
    try:
        return get_service().orders()
    except BrokerError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@router.post("/order/cancel", response_model=CancelResult)
def broker_order_cancel(req: CancelRequest) -> CancelResult:
    try:
        return get_service().cancel(req.order_id)
    except OrderValidationError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except BrokerError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
