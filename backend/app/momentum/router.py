"""Momentum Research router: read-only picks + one-tap basket buy (owner-only).

Endpoints (all under API_PREFIX + /momentum):
  GET  /momentum/picks            -> Stage-3b momentum top-N (read-only)
  POST /momentum/basket/preview   -> preview N market BUY orders (no placement)
  POST /momentum/basket/buy       -> place N market BUY orders on Moomoo LIVE

The basket endpoints REUSE the existing, hardened Moomoo order path
(preview/place: kill-switch + notional cap + trade PIN + MARKET fractional).
No new order plumbing. Owner-gated exactly like the rest of /moomoo.

Sizing is MANUAL: the caller supplies per_position_usd; we convert to a
fractional MARKET quantity per pick from its last price. Exit is NOT a tight
stop -- these are monthly-hold positions; the user rebalances monthly.
"""
from __future__ import annotations

import logging
from typing import List, Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from .service import MomentumService

API_PREFIX = "/v1"

logger = logging.getLogger("tradewiz.momentum.router")

router = APIRouter(prefix=f"{API_PREFIX}/momentum", tags=["momentum"])

_service: Optional[MomentumService] = None


def set_service(service: MomentumService) -> None:
    global _service
    _service = service


def get_service() -> MomentumService:
    if _service is None:
        raise HTTPException(status_code=503, detail="Momentum service not ready.")
    return _service


# -- response/request models ------------------------------------------------ #
class MomentumPickModel(BaseModel):
    symbol: str
    rank: int
    momentum: float
    last_price: float
    median_dollar_vol: float


class MomentumPicksModel(BaseModel):
    picks: List[MomentumPickModel]
    universe_size: int
    tradable_size: int
    top_n: int
    regime: str
    regime_note: str
    stage: str
    disclaimer: str
    generated_at: str


class BasketBuyRequest(BaseModel):
    symbols: List[str] = Field(..., min_length=1, max_length=25)
    per_position_usd: float = Field(..., gt=0)
    confirm: bool = False
    trade_pin: Optional[str] = None


class BasketLegPreview(BaseModel):
    symbol: str
    last_price: float
    quantity: float
    est_notional: float


class BasketPreviewModel(BaseModel):
    legs: List[BasketLegPreview]
    per_position_usd: float
    total_est_notional: float
    max_notional_per_order: float
    disclaimer: str


class BasketLegResult(BaseModel):
    symbol: str
    ok: bool
    order_id: Optional[str] = None
    quantity: float = 0.0
    status: Optional[str] = None
    error: Optional[str] = None


class BasketBuyResultModel(BaseModel):
    live: bool
    placed: int
    failed: int
    legs: List[BasketLegResult]


# -- read-only picks -------------------------------------------------------- #
@router.get("/picks", response_model=MomentumPicksModel)
def momentum_picks(top_n: int = 10) -> MomentumPicksModel:
    p = get_service().picks(top_n=top_n)
    return MomentumPicksModel(
        picks=[MomentumPickModel(**vars(x)) for x in p.picks],
        universe_size=p.universe_size,
        tradable_size=p.tradable_size,
        top_n=p.top_n,
        regime=p.regime,
        regime_note=p.regime_note,
        stage=p.stage,
        disclaimer=p.disclaimer,
        generated_at=p.generated_at,
    )


# -- basket buy (owner-only, reuses hardened moomoo order path) ------------- #
def _last_price(symbol: str) -> float:
    """Best-effort last price from the momentum service's cache."""
    svc = get_service()
    df = svc._frame(symbol)  # noqa: SLF001 - same package, deliberate reuse
    if df is None:
        return 0.0
    try:
        return float(df["Adj Close"].iloc[-1])
    except Exception:  # noqa: BLE001
        return 0.0


def _qty_for(symbol: str, per_position_usd: float) -> tuple[float, float]:
    px = _last_price(symbol)
    if px <= 0:
        return 0.0, 0.0
    qty = round(per_position_usd / px, 4)   # fractional MARKET qty
    return qty, px


def _moomoo():
    # Lazy import to avoid a hard import cycle at module load.
    from ..moomoo.router import _require_owner, get_service as moomoo_service
    return _require_owner, moomoo_service


@router.post("/basket/preview", response_model=BasketPreviewModel)
def basket_preview(
    req: BasketBuyRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> BasketPreviewModel:
    require_owner, moomoo_service = _moomoo()
    require_owner(authorization, x_moomoo_secret)
    svc = moomoo_service()
    legs: List[BasketLegPreview] = []
    total = 0.0
    cap = 0.0
    for sym in req.symbols:
        qty, px = _qty_for(sym, req.per_position_usd)
        est = round(qty * px, 2)   # our own estimate from cached last price
        try:
            pv = svc.preview(sym, "BUY", qty, "MARKET", None)
            cap = float(pv.get("max_notional", cap))
            # Only trust Moomoo's est if it is positive; for un-held MARKET names
            # OpenD may return 0, so keep our cached-price estimate instead.
            moomoo_est = float(pv.get("est_notional", 0.0) or 0.0)
            if moomoo_est > 0:
                est = moomoo_est
        except Exception as exc:  # noqa: BLE001 - preview is best-effort
            logger.info("basket preview leg %s failed: %s", sym, exc)
        total += est
        legs.append(BasketLegPreview(
            symbol=sym, last_price=round(px, 4), quantity=qty, est_notional=est,
        ))
    return BasketPreviewModel(
        legs=legs,
        per_position_usd=req.per_position_usd,
        total_est_notional=round(total, 2),
        max_notional_per_order=cap,
        disclaimer=get_service().picks(top_n=1).disclaimer,
    )


@router.post("/basket/buy", response_model=BasketBuyResultModel)
def basket_buy(
    req: BasketBuyRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> BasketBuyResultModel:
    require_owner, moomoo_service = _moomoo()
    uid = require_owner(authorization, x_moomoo_secret)
    if not req.confirm:
        raise HTTPException(status_code=428, detail="Set confirm=true to place live orders.")
    svc = moomoo_service()
    legs: List[BasketLegResult] = []
    placed = failed = 0
    for sym in req.symbols:
        qty, px = _qty_for(sym, req.per_position_usd)
        if qty <= 0:
            failed += 1
            legs.append(BasketLegResult(symbol=sym, ok=False, error="no price / qty"))
            continue
        try:
            r = svc.place(sym, "BUY", qty, "MARKET", None, True, trade_pin=req.trade_pin)
            placed += 1
            legs.append(BasketLegResult(
                symbol=sym, ok=True, order_id=r.order_id,
                quantity=r.qty, status=r.status,
            ))
            logger.warning(
                "MOMENTUM BASKET leg placed by uid=%s: BUY %s %s order=%s",
                uid, r.qty, sym, r.order_id,
            )
        except Exception as exc:  # noqa: BLE001 - one leg failing must not abort the rest
            failed += 1
            legs.append(BasketLegResult(symbol=sym, ok=False, error=str(exc)))
            logger.warning("MOMENTUM BASKET leg %s FAILED: %s", sym, exc)
    return BasketBuyResultModel(live=True, placed=placed, failed=failed, legs=legs)
