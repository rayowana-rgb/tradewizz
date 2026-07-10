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


class RebalanceScheduleModel(BaseModel):
    # "none" (no clock yet) | "due" (rebalance now) | "upcoming"
    status: str
    last_rebalance_date: Optional[str] = None
    due_date: Optional[str] = None
    trading_days_remaining: Optional[int] = None
    note: str


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
    # When the next monthly rebalance is due (from the local momentum ledger).
    rebalance: RebalanceScheduleModel


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


class SleeveModel(BaseModel):
    name: str                       # momentum | passive | cash
    market_value: float             # current USD value of this sleeve
    weight: float                   # current fraction of total account value
    target_weight: float            # owner's target fraction (50/30/20)
    drift: float                    # weight - target_weight (signed)
    positions: int                  # number of live names in this sleeve
    unrealized_pl: float            # sum of unrealized P/L for this sleeve
    return_pct: Optional[float] = None    # total return from recorded history
    max_drawdown: Optional[float] = None  # worst peak-to-trough (resilience)
    history_points: int = 0         # how many real observations exist


class SleevesModel(BaseModel):
    sleeves: List[SleeveModel]
    total_value: float              # momentum + passive + cash
    generated_at: str
    # True once there is >= 2 recorded observations so return/drawdown are real.
    metrics_ready: bool


# -- read-only picks -------------------------------------------------------- #
@router.get("/picks", response_model=MomentumPicksModel)
def momentum_picks(top_n: int = 10) -> MomentumPicksModel:
    svc = get_service()
    p = svc.picks(top_n=top_n)

    # Rebalance clock from the local momentum ledger (honest: None -> "none").
    from .ledger import MomentumLedger
    try:
        last_ts = MomentumLedger().last_rebalance_ts()
    except Exception as exc:  # noqa: BLE001 - never fail picks over the clock
        logger.info("rebalance ledger read failed: %s", exc)
        last_ts = None
    sched = svc.rebalance_schedule(last_ts)

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
        rebalance=RebalanceScheduleModel(
            status=sched.status,
            last_rebalance_date=sched.last_rebalance_date,
            due_date=sched.due_date,
            trading_days_remaining=sched.trading_days_remaining,
            note=sched.note,
        ),
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


@router.get("/sleeves", response_model=SleevesModel)
def momentum_sleeves(
    authorization: Optional[str] = Header(default=None),
    x_moomoo_secret: Optional[str] = Header(default=None),
) -> SleevesModel:
    """Split the ONE live account into strategy sleeves for the A/B test.

    momentum = live positions the momentum ledger owns; passive = every other
    live position; cash = the account's free cash (the dry-powder buffer).
    Reports each sleeve's current value, weight vs the owner's 50/30/20 target,
    and -- from the recorded per-sleeve history -- total return and max
    drawdown (the resilience measure). All values are real observations; the
    call also records a fresh history point so the comparison can be tracked
    over time. No metrics are fabricated: return/drawdown stay null until there
    are at least two recorded observations.
    """
    require_owner, moomoo_service = _moomoo()
    require_owner(authorization, x_moomoo_secret)
    svc = moomoo_service()

    from .ledger import MomentumLedger
    from .sleeves import SleeveTracker, TARGET_ALLOCATION, sleeve_metrics
    from datetime import datetime, timezone

    ledger_syms = {s.upper() for s in MomentumLedger().symbols()}

    # Live positions -> split into momentum vs passive.
    mom_mv = pas_mv = 0.0
    mom_pl = pas_pl = 0.0
    mom_n = pas_n = 0
    try:
        for pos in svc.positions():
            qty = float(pos.qty)
            if qty <= 0:
                continue
            mv = qty * float(pos.last_price)
            pl = float(pos.pl_val)
            if pos.symbol.upper() in ledger_syms:
                mom_mv += mv
                mom_pl += pl
                mom_n += 1
            else:
                pas_mv += mv
                pas_pl += pl
                pas_n += 1
    except Exception as exc:  # noqa: BLE001 - positions best-effort
        logger.info("sleeves positions lookup failed: %s", exc)

    # Cash (the buffer sleeve) from the account.
    cash = 0.0
    try:
        cash = float(svc.account().cash)
    except Exception as exc:  # noqa: BLE001
        logger.info("sleeves account lookup failed: %s", exc)

    # Record this real observation, then compute metrics over full history.
    tracker = SleeveTracker()
    tracker.record(momentum=mom_mv, passive=pas_mv, cash=cash)
    history = tracker.history()
    metrics = sleeve_metrics(history)

    total = mom_mv + pas_mv + cash

    def _weight(v: float) -> float:
        return round(v / total, 4) if total else 0.0

    def _sleeve(name: str, mv: float, pl: float, n: int) -> SleeveModel:
        w = _weight(mv)
        tw = TARGET_ALLOCATION.get(name, 0.0)
        m = metrics.get(name, {})
        rp = m.get("return_pct")
        dd = m.get("max_drawdown")
        return SleeveModel(
            name=name,
            market_value=round(mv, 2),
            weight=w,
            target_weight=tw,
            drift=round(w - tw, 4),
            positions=n,
            unrealized_pl=round(pl, 2),
            return_pct=round(rp, 6) if rp is not None else None,
            max_drawdown=round(dd, 6) if dd is not None else None,
            history_points=m.get("points", 0),
        )

    sleeves = [
        _sleeve("momentum", mom_mv, mom_pl, mom_n),
        _sleeve("passive", pas_mv, pas_pl, pas_n),
        _sleeve("cash", cash, 0.0, 0),
    ]

    return SleevesModel(
        sleeves=sleeves,
        total_value=round(total, 2),
        generated_at=datetime.now(timezone.utc).isoformat(),
        metrics_ready=len(history) >= 2,
    )
