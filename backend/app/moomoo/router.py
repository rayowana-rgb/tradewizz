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
    MoomooBracketList,
    MoomooBracketModel,
    MoomooBracketRequest,
    MoomooCancelResult,
    MoomooEquityHistory,
    MoomooEquityPoint,
    MoomooBoughtTodayList,
    MoomooManagerReport,
    MoomooOrderPreview,
    MoomooOpenOrderList,
    MoomooOpenOrderModel,
    MoomooOrderRequest,
    MoomooOrderResultModel,
    MoomooPositionList,
    MoomooPositionModel,
)
from ..portfolio_health.models import PortfolioHealth
from ..rebalance.models import RebalanceResponse
from .service import MoomooError, MoomooService
from .sltp import Bracket, SLTPMonitor, SLTPStore

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/v1/broker/moomoo", tags=["moomoo-private"])

_service: Optional[MoomooService] = None
_analytics = None  # MoomooAnalytics; injected from main once health/score ready.
_sltp_monitor: Optional[SLTPMonitor] = None  # server-managed SL/TP brackets.


def set_service(service: MoomooService) -> None:
    global _service
    _service = service


def get_service() -> MoomooService:
    global _service
    if _service is None:
        _service = MoomooService()
    return _service


def set_analytics(analytics) -> None:
    global _analytics
    _analytics = analytics


def _get_analytics():
    if _analytics is None:
        raise HTTPException(
            status_code=503, detail="Moomoo analytics not ready."
        )
    return _analytics


def get_sltp_monitor() -> SLTPMonitor:
    """Lazily build the server-managed SL/TP monitor over the live service."""
    global _sltp_monitor
    if _sltp_monitor is None:
        _sltp_monitor = SLTPMonitor(get_service(), SLTPStore())
    return _sltp_monitor


def _bracket_model(b: Bracket) -> MoomooBracketModel:
    return MoomooBracketModel(
        symbol=b.symbol, quantity=b.qty,
        reference_price=b.reference_price,
        stop_pct=b.stop_pct, target_pct=b.target_pct,
        stop_price=b.stop_price, target_price=b.target_price,
        status=b.status, created_ts=b.created_ts, updated_ts=b.updated_ts,
        triggered_ts=b.triggered_ts, triggered_price=b.triggered_price,
        order_id=b.order_id, note=b.note,
    )


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
        realized_pl=a.realized_pl,
    )


@router.get("/account/history", response_model=MoomooEquityHistory)
def moomoo_account_history(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooEquityHistory:
    _require_owner(authorization, x_moomoo_secret)
    points = get_service().equity_tracker.history()
    return MoomooEquityHistory(
        points=[
            MoomooEquityPoint(ts=p.ts, equity=p.equity) for p in points
        ],
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


@router.get("/orders", response_model=MoomooOpenOrderList)
def moomoo_open_orders(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooOpenOrderList:
    """Still-working (pending / partially filled) orders for the live account.

    Surfaced so the app can flag Rebalancing AI rows that already have an
    order in flight (e.g. submitted while the market is closed).
    """
    _require_owner(authorization, x_moomoo_secret)
    try:
        orders = get_service().open_orders()
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooOpenOrderList(
        orders=[
            MoomooOpenOrderModel(
                order_id=o.order_id, code=o.code, symbol=o.symbol,
                side=o.side, quantity=o.qty, filled_quantity=o.filled_qty,
                price=o.price, status=o.status,
            )
            for o in orders
        ]
    )


@router.get("/bought-today", response_model=MoomooBoughtTodayList)
def moomoo_bought_today(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooBoughtTodayList:
    """Bare symbols with a BUY order placed today (held or already sold).

    Lets a LIVE "Buy all" skip names already bought today even when the
    position is no longer held.
    """
    _require_owner(authorization, x_moomoo_secret)
    try:
        symbols = get_service().bought_today_symbols()
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooBoughtTodayList(symbols=symbols)


@router.get("/manager", response_model=MoomooManagerReport)
def moomoo_manager(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooManagerReport:
    """Rule-based portfolio analysis over the LIVE Moomoo holdings."""
    _require_owner(authorization, x_moomoo_secret)
    try:
        report = get_service().manager_report()
    except MoomooError as exc:
        raise _handle(exc)
    return MoomooManagerReport(**report)


@router.get("/health", response_model=PortfolioHealth)
def moomoo_health(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> PortfolioHealth:
    """Portfolio Health over the LIVE Moomoo holdings (real scoring engine)."""
    _require_owner(authorization, x_moomoo_secret)
    try:
        report = _get_analytics().health()
    except MoomooError as exc:
        raise _handle(exc)
    # The shared model carries simulated=True; live holdings are real.
    report.simulated = False
    return report


@router.get("/rebalance", response_model=RebalanceResponse)
def moomoo_rebalance(
    profile: Optional[str] = None,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> RebalanceResponse:
    """Portfolio Rebalancing AI over the LIVE Moomoo holdings."""
    _require_owner(authorization, x_moomoo_secret)
    try:
        report = _get_analytics().rebalance(profile=profile)
    except MoomooError as exc:
        raise _handle(exc)
    report.simulated = False
    return report


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


# -- server-managed stop-loss / take-profit ("bracket") -------------------- #
@router.get("/brackets", response_model=MoomooBracketList)
def moomoo_brackets(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooBracketList:
    """All server-managed SL/TP brackets (active first, then history)."""
    _require_owner(authorization, x_moomoo_secret)
    items = get_sltp_monitor().store.list()
    return MoomooBracketList(
        brackets=[_bracket_model(b) for b in items]
    )


@router.post("/brackets", response_model=MoomooBracketModel)
def moomoo_attach_bracket(
    req: MoomooBracketRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooBracketModel:
    """Attach (or replace) a -stop% / +target% bracket on a position.

    The monitor polls live prices and submits a MARKET sell when a level is
    touched (OCO is implicit: firing one leg retires the bracket).
    """
    uid = _require_owner(authorization, x_moomoo_secret)
    try:
        b = get_sltp_monitor().store.attach(
            req.symbol, req.quantity, req.reference_price,
            stop_pct=req.stop_pct, target_pct=req.target_pct,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    logger.warning(
        "MOOMOO SLTP bracket attached by uid=%s: %s qty=%s ref=%s "
        "stop=%s%% target=%s%%",
        uid, b.symbol, b.qty, b.reference_price, b.stop_pct, b.target_pct,
    )
    return _bracket_model(b)


@router.delete("/brackets/{symbol}", response_model=MoomooBracketModel)
def moomoo_cancel_bracket(
    symbol: str,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooBracketModel:
    _require_owner(authorization, x_moomoo_secret)
    b = get_sltp_monitor().store.cancel(symbol)
    if b is None:
        raise HTTPException(
            status_code=404, detail="No active bracket for that symbol."
        )
    return _bracket_model(b)


@router.post("/brackets/check", response_model=MoomooBracketList)
def moomoo_check_brackets(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MoomooBracketList:
    """Run one monitor tick on demand and return the current brackets.

    The monitor also runs automatically from the background warmer loop; this
    endpoint lets the app force an immediate evaluation (e.g. on app open).
    """
    _require_owner(authorization, x_moomoo_secret)
    mon = get_sltp_monitor()
    try:
        mon.tick()
    except Exception:  # noqa: BLE001 - tick is already defensive
        pass
    return MoomooBracketList(
        brackets=[_bracket_model(b) for b in mon.store.list()]
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
