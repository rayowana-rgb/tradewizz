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


class RebalanceSellLeg(BaseModel):
    symbol: str
    quantity: float        # shares to sell (the whole momentum holding)
    last_price: float
    est_notional: float


class RebalanceBuyLeg(BaseModel):
    symbol: str
    rank: int
    quantity: float        # fractional MARKET qty from per_position_usd
    last_price: float
    est_notional: float


class RebalancePreviewModel(BaseModel):
    # Symbols currently held via momentum that dropped out of the new top-N.
    sells: List[RebalanceSellLeg]
    # New top-N names not yet held via momentum.
    buys: List[RebalanceBuyLeg]
    # Momentum names that stay in the top-N (no action).
    holds: List[str]
    per_position_usd: float
    max_notional_per_order: float
    disclaimer: str


class MomentumHoldingModel(BaseModel):
    symbol: str
    # Live position (from Moomoo); 0 if the ledger name is no longer held.
    qty: float
    cost_price: float
    last_price: float
    market_value: float
    unrealized_pl: float
    unrealized_pl_ratio: float   # fraction, e.g. 0.086 == +8.6%
    # True if the name is still in the current top-N (a HOLD next rebalance).
    in_top_n: bool
    rank: Optional[int] = None   # current top-N rank, when in_top_n
    first_bought_ts: int


class MomentumHoldingsModel(BaseModel):
    holdings: List[MomentumHoldingModel]
    total_market_value: float
    total_unrealized_pl: float
    top_n: int
    # Ledger symbols that are no longer held live (sold manually elsewhere).
    stale_symbols: List[str]
    generated_at: str


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


# -- monthly rebalance (owner-only) ----------------------------------------- #
class RebalancePreviewRequest(BaseModel):
    per_position_usd: float = Field(..., gt=0)
    top_n: int = Field(10, ge=1, le=25)


@router.post("/rebalance/preview", response_model=RebalancePreviewModel)
def rebalance_preview(
    req: RebalancePreviewRequest,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> RebalancePreviewModel:
    """Diff the momentum-owned holdings against the fresh top-N.

    SELL  = momentum-owned names that dropped OUT of the new top-N.
    BUY   = new top-N names not currently held via momentum.
    HOLD  = momentum-owned names that remain in the top-N (no action).

    Only positions momentum actually bought (tracked in the local ledger and
    confirmed against the LIVE positions) are ever considered for selling, so
    the owner's other strategies are never touched.
    """
    require_owner, moomoo_service = _moomoo()
    require_owner(authorization, x_moomoo_secret)
    svc = moomoo_service()

    from .ledger import MomentumLedger
    ledger = MomentumLedger()

    # Fresh top-N target set.
    picks = get_service().picks(top_n=req.top_n)
    target_syms = {p.symbol.upper(): p for p in picks.picks}

    # Momentum-owned symbols per the ledger, intersected with what is actually
    # held LIVE (drops names the owner has since sold manually elsewhere).
    ledger_syms = {s.upper() for s in ledger.symbols()}
    live_qty: dict = {}
    try:
        for pos in svc.positions():
            live_qty[pos.symbol.upper()] = float(pos.can_sell_qty or pos.qty)
    except Exception as exc:  # noqa: BLE001 - positions best-effort
        logger.info("rebalance positions lookup failed: %s", exc)
    owned = {s for s in ledger_syms if live_qty.get(s, 0.0) > 0}

    cap = 0.0

    sells: List[RebalanceSellLeg] = []
    for sym in sorted(owned - set(target_syms)):
        qty = live_qty.get(sym, 0.0)
        px = _last_price(sym)
        sells.append(RebalanceSellLeg(
            symbol=sym, quantity=round(qty, 4), last_price=round(px, 4),
            est_notional=round(qty * px, 2),
        ))

    buys: List[RebalanceBuyLeg] = []
    for sym, pick in sorted(target_syms.items(), key=lambda kv: kv[1].rank):
        if sym in owned:
            continue
        qty, px = _qty_for(sym, req.per_position_usd)
        est = round(qty * px, 2)
        try:
            pv = svc.preview(sym, "BUY", qty, "MARKET", None)
            cap = float(pv.get("max_notional", cap))
            moomoo_est = float(pv.get("est_notional", 0.0) or 0.0)
            if moomoo_est > 0:
                est = moomoo_est
        except Exception as exc:  # noqa: BLE001 - preview best-effort
            logger.info("rebalance buy preview %s failed: %s", sym, exc)
        buys.append(RebalanceBuyLeg(
            symbol=sym, rank=pick.rank, quantity=qty,
            last_price=round(px, 4), est_notional=est,
        ))

    holds = sorted(owned & set(target_syms))

    return RebalancePreviewModel(
        sells=sells, buys=buys, holds=holds,
        per_position_usd=req.per_position_usd,
        max_notional_per_order=cap,
        disclaimer=picks.disclaimer,
    )


# -- momentum holdings (owner-only, read-only) ------------------------------ #
@router.get("/holdings", response_model=MomentumHoldingsModel)
def momentum_holdings(
    top_n: int = 10,
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> MomentumHoldingsModel:
    """The positions momentum actually bought, joined with LIVE Moomoo data.

    Reads the local momentum ledger (symbols bought via the strategy) and joins
    each against the live Moomoo position for qty / cost / last price /
    unrealized P/L. Names still in the current top-N are flagged ``in_top_n``
    (a HOLD at the next rebalance). Ledger names no longer held live -- e.g.
    sold manually in another strategy -- are reported under ``stale_symbols``
    and excluded from the holdings list. Other strategies' positions are never
    shown, because only ledger symbols are considered.
    """
    require_owner, moomoo_service = _moomoo()
    require_owner(authorization, x_moomoo_secret)
    svc = moomoo_service()

    from .ledger import MomentumLedger
    ledger = MomentumLedger()
    ledger_entries = {e.symbol.upper(): e for e in ledger.entries()}

    # Current top-N, for the in_top_n / rank flags.
    picks = get_service().picks(top_n=top_n)
    rank_by_sym = {p.symbol.upper(): p.rank for p in picks.picks}

    # Live positions keyed by symbol.
    live: dict = {}
    try:
        for pos in svc.positions():
            live[pos.symbol.upper()] = pos
    except Exception as exc:  # noqa: BLE001 - positions best-effort
        logger.info("holdings positions lookup failed: %s", exc)

    holdings: List[MomentumHoldingModel] = []
    stale: List[str] = []
    total_mv = 0.0
    total_pl = 0.0
    for sym, entry in sorted(ledger_entries.items()):
        pos = live.get(sym)
        qty = float(pos.qty) if pos else 0.0
        if qty <= 0:
            # Ledger says momentum owns it but it is not held live any more.
            stale.append(sym)
            continue
        last_px = float(pos.last_price) if pos else 0.0
        mv = round(qty * last_px, 2)
        total_mv += mv
        total_pl += float(pos.pl_val) if pos else 0.0
        holdings.append(MomentumHoldingModel(
            symbol=sym,
            qty=round(qty, 4),
            cost_price=round(float(pos.cost_price), 4) if pos else 0.0,
            last_price=round(last_px, 4),
            market_value=mv,
            unrealized_pl=round(float(pos.pl_val), 2) if pos else 0.0,
            unrealized_pl_ratio=round(float(pos.pl_ratio), 6) if pos else 0.0,
            in_top_n=sym in rank_by_sym,
            rank=rank_by_sym.get(sym),
            first_bought_ts=entry.first_bought_ts,
        ))

    return MomentumHoldingsModel(
        holdings=holdings,
        total_market_value=round(total_mv, 2),
        total_unrealized_pl=round(total_pl, 2),
        top_n=top_n,
        stale_symbols=stale,
        generated_at=picks.generated_at,
    )
