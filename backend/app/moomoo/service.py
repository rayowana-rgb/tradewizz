"""Moomoo LIVE trading service — talks to a local OpenD gateway via moomoo_api.

Single-user / private. All public errors are raised as ``MoomooError`` with an
HTTP status so the router can surface them cleanly.

Guard-rails enforced here (defence in depth; the router gates access):
  * Kill-switch:  TRADEWIZZ_MOOMOO_LIVE_DISABLED=1  -> all order placement 403.
  * Notional cap: TRADEWIZZ_MOOMOO_MAX_NOTIONAL (USD, default 1000) per order.
  * Symbols are normalised to ``US.<SYM>``; only the US market is supported.
"""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass
from typing import List, Optional

# moomoo_api is imported lazily inside _ctx() so the rest of the backend (and
# the test-suite) never needs OpenD running just to import this module.


class MoomooError(Exception):
    def __init__(self, message: str, status_code: int = 400) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


# Portfolio-manager thresholds (allocation-based, mirror the simulation rules).
CONCENTRATION_WARN = 0.35       # 35% of holdings in one name -> warning
CONCENTRATION_CRITICAL = 0.55   # 55% -> critical
CASH_FLOOR = 0.05               # < 5% cash limits flexibility


def _env_host() -> str:
    return os.environ.get("TRADEWIZZ_MOOMOO_HOST", "127.0.0.1")


def _env_port() -> int:
    return int(os.environ.get("TRADEWIZZ_MOOMOO_PORT", "11111"))


def _env_acc_id() -> int:
    raw = os.environ.get("TRADEWIZZ_MOOMOO_ACC_ID", "283726802523722626")
    return int(raw)


def _max_notional() -> float:
    return float(os.environ.get("TRADEWIZZ_MOOMOO_MAX_NOTIONAL", "1000"))


def _live_disabled() -> bool:
    return os.environ.get("TRADEWIZZ_MOOMOO_LIVE_DISABLED", "") in ("1", "true", "True")


def _norm_symbol(symbol: str) -> str:
    s = (symbol or "").strip().upper()
    if not s:
        raise MoomooError("Symbol is required.", 422)
    if s.startswith("US."):
        return s
    # Strip any other market prefix and force US.
    if "." in s:
        s = s.split(".", 1)[1]
    return f"US.{s}"


@dataclass
class MoomooAccount:
    total_assets: float
    cash: float
    buying_power: float
    market_value: float
    currency: str
    # Broker-reported cumulative realized profit/loss on the account
    # (gains booked from closed positions). Real SDK value, never fabricated.
    realized_pl: float = 0.0


@dataclass
class MoomooPosition:
    code: str
    symbol: str
    qty: float
    can_sell_qty: float
    cost_price: float
    last_price: float
    pl_val: float
    pl_ratio: float


@dataclass
class MoomooOrderResult:
    order_id: str
    code: str
    side: str
    order_type: str
    qty: float
    price: float
    status: str
    live: bool


@dataclass
class MoomooOpenOrder:
    """A still-working (not yet fully filled / terminal) order.

    Used to flag Rebalancing AI rows that already have a pending order so the
    user is not told to ADD/EXIT/REDUCE something they have already executed
    (e.g. an order submitted while the market is closed, waiting to fill).
    """

    order_id: str
    code: str
    symbol: str
    side: str  # 'BUY' or 'SELL'
    qty: float
    filled_qty: float
    price: float
    status: str


class MoomooService:
    """Thin, thread-safe wrapper around a single OpenSecTradeContext."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._ctx = None  # type: ignore
        from app.moomoo.equity_tracker import EquityTracker
        self._equity = EquityTracker()

    @property
    def equity_tracker(self):
        return self._equity

    # -- connection -------------------------------------------------------
    def _ctx_obj(self):
        if self._ctx is not None:
            return self._ctx
        try:
            from moomoo import (  # type: ignore
                OpenSecTradeContext,
                TrdMarket,
                SecurityFirm,
            )
        except Exception as exc:  # pragma: no cover - import guard
            raise MoomooError(
                f"Moomoo SDK is not available: {exc}", 503
            )
        try:
            self._ctx = OpenSecTradeContext(
                filter_trdmarket=TrdMarket.US,
                host=_env_host(),
                port=_env_port(),
                security_firm=SecurityFirm.FUTUSG,
            )
        except Exception as exc:
            raise MoomooError(
                "Could not reach the local Moomoo OpenD gateway. "
                "Is OpenD running and logged in?",
                503,
            )
        return self._ctx

    def _check_ok(self, ret, data):
        from moomoo import RET_OK  # type: ignore

        if ret != RET_OK:
            raise MoomooError(str(data), 502)
        return data

    def _unlock(self, ctx, trade_pin: str) -> None:
        """Unlock the REAL trade context with the user's trade PIN.

        The PIN is supplied per-request and is NEVER stored on disk. It is
        passed straight to OpenD's unlock_trade() and then discarded. We send
        it as an MD5 (what the SDK expects for the ciphertext path); if the
        caller already provided a 32-char hex digest we use it as-is.

        NOTE: the *visualization* (GUI) build of OpenD refuses API unlock and
        demands a manual click in its window. In that setup the operator must
        unlock manually once; set TRADEWIZZ_MOOMOO_SKIP_UNLOCK=1 to skip this
        call and rely on the manual unlock.
        """
        if os.environ.get("TRADEWIZZ_MOOMOO_SKIP_UNLOCK", "") in (
            "1", "true", "True"
        ):
            return
        pin = (trade_pin or "").strip()
        if not pin:
            raise MoomooError(
                "Trade PIN is required to place a live order.", 428
            )
        import hashlib
        import re

        if re.fullmatch(r"[0-9a-fA-F]{32}", pin):
            pin_md5 = pin.lower()
        else:
            pin_md5 = hashlib.md5(pin.encode("utf-8")).hexdigest()
        ret, data = ctx.unlock_trade(password_md5=pin_md5, is_unlock=True)
        try:
            from moomoo import RET_OK  # type: ignore

            if ret != RET_OK:
                # Don't leak the PIN; surface OpenD's message only.
                raise MoomooError(
                    f"Trade unlock failed: {data}", 403
                )
        finally:
            pin = ""
            pin_md5 = ""

    # -- read -------------------------------------------------------------
    def account(self) -> MoomooAccount:
        from moomoo import TrdEnv  # type: ignore

        with self._lock:
            ctx = self._ctx_obj()
            ret, data = ctx.accinfo_query(
                trd_env=TrdEnv.REAL, acc_id=_env_acc_id(), currency="USD"
            )
            data = self._check_ok(ret, data)
        row = data.iloc[0]

        def _f(col: str) -> float:
            try:
                v = row.get(col)
                return float(v) if v not in (None, "N/A") else 0.0
            except Exception:
                return 0.0

        acct = MoomooAccount(
            total_assets=_f("total_assets"),
            cash=_f("cash"),
            buying_power=_f("power"),
            market_value=_f("market_val"),
            currency="USD",
            realized_pl=_f("realized_pl"),
        )
        # Record this real observation so the portfolio-growth chart can be
        # built from genuine data points (no fabricated history).
        try:
            self._equity.record(acct.total_assets)
        except Exception:
            pass
        return acct

    def positions(self) -> List[MoomooPosition]:
        from moomoo import TrdEnv  # type: ignore

        with self._lock:
            ctx = self._ctx_obj()
            ret, data = ctx.position_list_query(
                trd_env=TrdEnv.REAL, acc_id=_env_acc_id()
            )
            data = self._check_ok(ret, data)
        out: List[MoomooPosition] = []
        for _, r in data.iterrows():
            code = str(r.get("code", ""))
            sym = code.split(".", 1)[1] if "." in code else code

            def _f(col: str) -> float:
                try:
                    v = r.get(col)
                    return float(v) if v not in (None, "N/A") else 0.0
                except Exception:
                    return 0.0

            # The Moomoo SDK returns pl_ratio already in PERCENT units
            # (e.g. 1.86 means +1.86%). The rest of the app (Flutter UI and
            # the manager rules below) treats pl_ratio as a FRACTION and
            # multiplies by 100, so normalise it to a fraction here at the
            # single ingestion point to avoid a 100x blow-up (e.g. 186%).
            pl_ratio_raw = _f("pl_ratio")
            pl_ratio = pl_ratio_raw / 100.0
            out.append(
                MoomooPosition(
                    code=code,
                    symbol=sym,
                    qty=_f("qty"),
                    can_sell_qty=_f("can_sell_qty"),
                    cost_price=_f("cost_price"),
                    last_price=_f("nominal_price"),
                    pl_val=_f("pl_val"),
                    pl_ratio=pl_ratio,
                )
            )
        return out

    def open_orders(self) -> List[MoomooOpenOrder]:
        """Return still-working orders (submitted / partially filled, etc.).

        These are orders that have NOT reached a terminal state — most
        importantly orders placed while the market is closed that are queued to
        fill at the next session. They are surfaced so Rebalancing AI can mark
        rows that already have a pending order in flight.
        """
        from moomoo import TrdEnv, OrderStatus  # type: ignore

        # "Working" = not yet terminal. Anything filled/cancelled/failed is
        # excluded so we only flag orders that still affect the position once
        # the market reopens.
        working = [
            OrderStatus.SUBMITTING,
            OrderStatus.SUBMITTED,
            OrderStatus.WAITING_SUBMIT,
            OrderStatus.FILLED_PART,
        ]
        with self._lock:
            ctx = self._ctx_obj()
            ret, data = ctx.order_list_query(
                status_filter_list=working,
                trd_env=TrdEnv.REAL,
                acc_id=_env_acc_id(),
            )
            data = self._check_ok(ret, data)
        out: List[MoomooOpenOrder] = []
        for _, r in data.iterrows():
            code = str(r.get("code", ""))
            sym = code.split(".", 1)[1] if "." in code else code

            def _f(col: str) -> float:
                try:
                    v = r.get(col)
                    return float(v) if v not in (None, "N/A") else 0.0
                except Exception:
                    return 0.0

            raw_dir = str(r.get("trd_side", "") or "").upper()
            side = "SELL" if "SELL" in raw_dir else "BUY"
            out.append(
                MoomooOpenOrder(
                    order_id=str(r.get("order_id", "") or ""),
                    code=code,
                    symbol=sym,
                    side=side,
                    qty=_f("qty"),
                    filled_qty=_f("dealt_qty"),
                    price=_f("price"),
                    status=str(r.get("order_status", "") or ""),
                )
            )
        return out

    def bought_today_symbols(self) -> List[str]:
        """Bare symbols that have a BUY order placed TODAY.

        Used so a LIVE "Buy all" can skip names already bought today even if
        the position is no longer held (e.g. bought then sold the same day).
        ``order_list_query`` with no date range returns the current trading
        day's orders. A symbol counts as bought-today if a BUY order either
        actually filled some quantity (``dealt_qty`` > 0) or is still working
        (submitted / waiting / partially filled). Failed / cancelled-with-no-
        fill BUYs do not count.
        """
        from moomoo import TrdEnv, OrderStatus  # type: ignore

        working = {
            str(OrderStatus.SUBMITTING), str(OrderStatus.SUBMITTED),
            str(OrderStatus.WAITING_SUBMIT), str(OrderStatus.FILLED_PART),
        }
        with self._lock:
            ctx = self._ctx_obj()
            # No start/end -> today's orders for the real account.
            ret, data = ctx.order_list_query(
                trd_env=TrdEnv.REAL,
                acc_id=_env_acc_id(),
            )
            data = self._check_ok(ret, data)
        out: set = set()
        for _, r in data.iterrows():
            raw_dir = str(r.get("trd_side", "") or "").upper()
            if "BUY" not in raw_dir:
                continue
            try:
                dealt = float(r.get("dealt_qty") or 0)
            except Exception:  # noqa: BLE001
                dealt = 0.0
            status = str(r.get("order_status", "") or "")
            if dealt <= 0 and status not in working:
                continue
            code = str(r.get("code", ""))
            sym = code.split(".", 1)[1] if "." in code else code
            if sym:
                out.add(sym.upper())
        return sorted(out)

    def manager_report(self) -> dict:
        """Rule-based portfolio analysis over the LIVE Moomoo holdings.

        Uses only allocation data we already retrieve (per-position market
        value, cost basis, P/L, and account cash) — no extra data source, no
        LLM, no fabricated numbers. Metrics:
          * concentration / largest single-name share
          * cash allocation %
          * diversification (# of holdings)
          * overall risk level
        Recommendations are derived from these real numbers.
        """
        acct = self.account()
        positions = self.positions()

        # Per-position market value = qty * last (nominal) price.
        values = {
            p.symbol: max(0.0, p.qty * p.last_price) for p in positions
        }
        market_total = sum(values.values())
        cash = float(acct.cash or 0.0)
        equity = float(acct.total_assets or 0.0)
        if equity <= 0:
            equity = cash + market_total
        cash_pct = (cash / equity * 100.0) if equity > 0 else 0.0

        largest_sym = None
        largest_pct = 0.0
        if market_total > 0:
            largest_sym, largest_val = max(
                values.items(), key=lambda kv: kv[1]
            )
            largest_pct = largest_val / market_total * 100.0

        recs: List[dict] = []
        if not positions:
            recs.append({
                "kind": "health", "severity": "info",
                "title": "No holdings yet",
                "message": (
                    "Your live account has no open positions. Allocation "
                    "analysis unlocks once you hold a few names."
                ),
            })
        else:
            # Concentration.
            if largest_sym is not None:
                if largest_pct >= CONCENTRATION_CRITICAL * 100:
                    recs.append({
                        "kind": "concentration", "severity": "critical",
                        "symbol": largest_sym,
                        "title": "High concentration",
                        "message": (
                            f"{largest_sym} is {largest_pct:.0f}% of holdings "
                            "value. Single-name risk is elevated."
                        ),
                    })
                elif largest_pct >= CONCENTRATION_WARN * 100:
                    recs.append({
                        "kind": "concentration", "severity": "warning",
                        "symbol": largest_sym,
                        "title": "Elevated concentration",
                        "message": (
                            f"{largest_sym} is {largest_pct:.0f}% of holdings "
                            "value. Consider trimming to diversify."
                        ),
                    })
            # Losing positions (real P/L).
            for p in positions:
                if p.pl_ratio <= -0.15:
                    recs.append({
                        "kind": "weak_position", "severity": "warning",
                        "symbol": p.symbol,
                        "title": "Position underwater",
                        "message": (
                            f"{p.symbol} is down {abs(p.pl_ratio) * 100:.0f}% "
                            "from cost. Review the thesis."
                        ),
                    })
            # Cash.
            if cash_pct < CASH_FLOOR * 100:
                recs.append({
                    "kind": "cash_allocation", "severity": "warning",
                    "title": "Low cash",
                    "message": (
                        "Cash is below 5% of equity. Buying flexibility is "
                        "limited."
                    ),
                })
            # Diversification.
            if len(positions) < 3:
                recs.append({
                    "kind": "diversification", "severity": "warning",
                    "title": "Low diversification",
                    "message": (
                        "Fewer than 3 holdings increases single-name risk."
                    ),
                })

        # Scores (0–100). Allocation-derived, no scoring engine needed.
        n = len(positions)
        diversification_score = min(n, 10) / 10.0 * 100.0
        concentration_score = max(0.0, 100.0 - largest_pct)
        if largest_pct >= CONCENTRATION_CRITICAL * 100 or n == 0:
            risk = "HIGH"
        elif (largest_pct < CONCENTRATION_WARN * 100 and n >= 3
              and cash_pct >= CASH_FLOOR * 100):
            risk = "LOW"
        else:
            risk = "MODERATE"

        return {
            "risk_level": risk,
            "concentration_score": round(concentration_score, 1),
            "diversification_score": round(diversification_score, 1),
            "cash_pct": round(cash_pct, 1),
            "largest_position_pct": round(largest_pct, 1),
            "holdings_count": n,
            "recommendations": recs,
            "live": True,
        }

    # -- order helpers ----------------------------------------------------
    def _est_notional(self, symbol: str, qty: float, price: float) -> float:
        if price and price > 0:
            return abs(qty) * price
        # MARKET order: estimate from last traded price for the cap check.
        try:
            for p in self.positions():
                if p.symbol == symbol.split(".", 1)[-1] and p.last_price > 0:
                    return abs(qty) * p.last_price
        except Exception:
            pass
        return 0.0

    def preview(
        self, symbol: str, side: str, qty: float, order_type: str,
        price: Optional[float],
    ) -> dict:
        code = _norm_symbol(symbol)
        sym = code.split(".", 1)[1]
        otype = (order_type or "MARKET").upper()
        if otype not in ("MARKET", "LIMIT"):
            raise MoomooError("order_type must be MARKET or LIMIT.", 422)
        if otype == "LIMIT" and (price is None or price <= 0):
            raise MoomooError("LIMIT orders require a positive price.", 422)
        if qty is None or qty <= 0:
            raise MoomooError("Quantity must be positive.", 422)
        # Fractional / odd-lot quantities are ONLY accepted by Moomoo for
        # MARKET orders (fractional shares trade at market). LIMIT orders
        # still require whole shares, otherwise the API returns
        # "Invalid quantity".
        is_fractional = float(qty) != int(qty)
        if is_fractional and otype != "MARKET":
            raise MoomooError(
                "Fractional quantities are only supported for MARKET "
                "orders. Use a whole number of shares for LIMIT orders.",
                422,
            )
        est = self._est_notional(code, qty, price or 0.0)
        cap = _max_notional()
        return {
            "code": code,
            "symbol": sym,
            "side": side.upper(),
            "order_type": otype,
            "quantity": float(qty),
            "price": float(price) if price else 0.0,
            "est_notional": round(est, 2),
            "max_notional": cap,
            "within_cap": (est <= cap) or est == 0.0,
            "live": True,
            "currency": "USD",
        }

    def place(
        self, symbol: str, side: str, qty: float, order_type: str,
        price: Optional[float], confirm: bool,
        trade_pin: Optional[str] = None,
        *,
        extended_hours: bool = False,
    ) -> MoomooOrderResult:
        # ``extended_hours`` lets a LIMIT order rest and fill in the pre/post/
        # overnight sessions instead of being rejected outside regular hours.
        # Only meaningful for LIMIT (MARKET cannot fill outside RTH).

        if _live_disabled():
            raise MoomooError(
                "Live trading is currently disabled (kill-switch on).", 403
            )
        if not confirm:
            raise MoomooError(
                "Live order requires confirm=true after preview.", 428
            )
        pv = self.preview(symbol, side, qty, order_type, price)
        if not pv["within_cap"] and pv["est_notional"] > 0:
            raise MoomooError(
                f"Order notional ${pv['est_notional']:.2f} exceeds the "
                f"per-order cap of ${pv['max_notional']:.2f}.",
                403,
            )
        from moomoo import (  # type: ignore
            TrdSide,
            OrderType,
            TrdEnv,
        )

        code = pv["code"]
        side_enum = TrdSide.BUY if side.upper() == "BUY" else TrdSide.SELL
        if pv["order_type"] == "MARKET":
            otype_enum = OrderType.MARKET
            order_price = 0.0
        else:
            otype_enum = OrderType.NORMAL
            order_price = float(price)

        # Optional extended-hours kwargs (pre/post/overnight). Built lazily so
        # the regular-hours path is byte-for-byte unchanged, and so we degrade
        # gracefully on SDK builds that lack Session / fill_outside_rth.
        extra: dict = {}
        if extended_hours and pv["order_type"] == "LIMIT":
            try:
                from moomoo import Session, TimeInForce  # type: ignore

                extra["session"] = Session.ALL
                extra["fill_outside_rth"] = True
                # GTC so a pending overnight/extended order survives until it
                # fills or the owner cancels it, rather than expiring at close.
                extra["time_in_force"] = TimeInForce.GTC
            except Exception:  # noqa: BLE001
                extra = {}

        with self._lock:
            ctx = self._ctx_obj()
            # REAL trading requires an unlocked context. Unlock with the
            # per-request PIN immediately before placing, never stored.
            self._unlock(ctx, trade_pin or "")
            ret, data = ctx.place_order(
                price=order_price,
                qty=float(qty),
                code=code,
                trd_side=side_enum,
                order_type=otype_enum,
                trd_env=TrdEnv.REAL,
                acc_id=_env_acc_id(),
                remark="tradewizz",
                **extra,
            )
            data = self._check_ok(ret, data)
        row = data.iloc[0]
        return MoomooOrderResult(
            order_id=str(row.get("order_id", "")),
            code=str(row.get("code", code)),
            side=str(row.get("trd_side", side.upper())),
            order_type=str(row.get("order_type", pv["order_type"])),
            qty=float(row.get("qty", qty) or qty),
            price=float(row.get("price", order_price) or order_price),
            status=str(row.get("order_status", "SUBMITTING")),
            live=True,
        )

    def cancel(self, order_id: str) -> dict:
        from moomoo import ModifyOrderOp, TrdEnv  # type: ignore

        with self._lock:
            ctx = self._ctx_obj()
            ret, data = ctx.modify_order(
                ModifyOrderOp.CANCEL, order_id, 0, 0,
                trd_env=TrdEnv.REAL, acc_id=_env_acc_id(),
            )
            self._check_ok(ret, data)
        return {"order_id": order_id, "status": "CANCELLED", "live": True}
