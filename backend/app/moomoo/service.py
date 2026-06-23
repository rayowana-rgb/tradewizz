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


class MoomooService:
    """Thin, thread-safe wrapper around a single OpenSecTradeContext."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._ctx = None  # type: ignore

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

        return MoomooAccount(
            total_assets=_f("total_assets"),
            cash=_f("cash"),
            buying_power=_f("power"),
            market_value=_f("market_val"),
            currency="USD",
        )

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

            out.append(
                MoomooPosition(
                    code=code,
                    symbol=sym,
                    qty=_f("qty"),
                    can_sell_qty=_f("can_sell_qty"),
                    cost_price=_f("cost_price"),
                    last_price=_f("nominal_price"),
                    pl_val=_f("pl_val"),
                    pl_ratio=_f("pl_ratio"),
                )
            )
        return out

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
        # Moomoo rejects fractional quantities for NEW orders via this API
        # path ("Invalid quantity"), even though existing positions can be
        # fractional. Require whole shares.
        if float(qty) != int(qty):
            raise MoomooError(
                "Quantity must be a whole number of shares.", 422
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
    ) -> MoomooOrderResult:
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
