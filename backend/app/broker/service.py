"""Broker service: safety, validation, confirmation tokens, dedup guard.

Enforces the safety constraints:
- preview NEVER places an order;
- place REQUIRES a valid, unexpired confirmation_token that matches the exact
  order parameters from a prior preview;
- unsupported markets/symbols fail with a clear message;
- order value/quantity caps;
- duplicate-order guard within a short time window;
- paper by default; real only when explicitly enabled.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import time
from typing import Dict, Optional, Tuple

from ..models import Market
from .client import BrokerClient, BrokerError, MockBrokerClient, MoomooBrokerClient
from .config import BrokerConfig
from .models import (
    AccountSummary,
    BrokerStatus,
    CancelResult,
    OpenOrder,
    OrderPreview,
    OrderResult,
    OrderSide,
    OrderType,
    OrdersResponse,
    Position,
    PositionsResponse,
)
from .symbol_map import (
    SymbolNotTradable,
    is_market_tradable,
    moomoo_currency,
    to_moomoo_code,
)

logger = logging.getLogger("tradewizz.broker")

REAL_WARNING = (
    "REAL TRADING ENABLED — orders placed here use real money. "
    "Every order still requires explicit confirmation."
)


class OrderValidationError(Exception):
    """Order failed a risk/validation check (mapped to HTTP 400)."""


def _token_secret() -> bytes:
    # Server-side only; not exposed to clients. Stable within a process run.
    return os.environ.get(
        "TRADEWIZZ_ORDER_TOKEN_SECRET", "tradewizz-dev-secret"
    ).encode()


class BrokerService:
    def __init__(
        self,
        config: Optional[BrokerConfig] = None,
        client: Optional[BrokerClient] = None,
        clock=time.time,
    ):
        self._config = config or BrokerConfig.from_env()
        # Default real client if none injected (tests inject a MockBrokerClient).
        self._client = client or MoomooBrokerClient(self._config)
        self._clock = clock
        # order signature -> last placement time (duplicate guard).
        self._recent: Dict[str, float] = {}

    @property
    def config(self) -> BrokerConfig:
        return self._config

    # -- status / account / positions ------------------------------------

    def status(self) -> BrokerStatus:
        try:
            connected = self._client.is_connected()
        except Exception as exc:  # noqa: BLE001
            logger.warning("broker status check failed: %s", exc)
            connected = False
        return BrokerStatus(
            connected=connected,
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            host=self._config.host,
            port=self._config.port,
            warning=REAL_WARNING if self._config.is_real else None,
            message=(
                "Connected to Moomoo OpenD"
                if connected
                else "Moomoo OpenD not reachable"
            ),
        )

    def account(self) -> AccountSummary:
        if not self._client.is_connected():
            return AccountSummary(
                connected=False, trading_env=self._config.trading_env_label
            )
        data = self._client.account_summary()
        return AccountSummary(
            connected=True,
            currency=data.get("currency", ""),
            cash=data.get("cash", 0.0),
            buying_power=data.get("buying_power", 0.0),
            total_assets=data.get("total_assets", 0.0),
            trading_env=self._config.trading_env_label,
        )

    def positions(self) -> PositionsResponse:
        if not self._client.is_connected():
            return PositionsResponse(connected=False, positions=[])
        rows = self._client.positions()
        out = []
        for r in rows:
            out.append(Position(
                symbol=str(r.get("code", "")),
                market=Market.HKEX,  # Moomoo positions here are HK-scoped
                quantity=r.get("quantity", 0.0),
                cost_price=r.get("cost_price", 0.0),
                current_price=r.get("current_price", 0.0),
                market_value=r.get("market_value", 0.0),
                pl_value=r.get("pl_value", 0.0),
            ))
        return PositionsResponse(connected=True, positions=out)

    # -- validation ------------------------------------------------------

    def _resolve_code(self, symbol: str, market: Market) -> str:
        if not is_market_tradable(market):
            raise OrderValidationError("This symbol is not tradable via Moomoo.")
        try:
            return to_moomoo_code(symbol, market)
        except SymbolNotTradable as exc:
            raise OrderValidationError(exc.message) from exc

    def _validate(
        self,
        symbol: str,
        market: Market,
        side: OrderSide,
        quantity: float,
        order_type: OrderType,
        price: Optional[float],
    ) -> Tuple[str, float, list]:
        code = self._resolve_code(symbol, market)
        warnings: list = []

        if quantity <= 0:
            raise OrderValidationError("Quantity must be greater than zero.")
        if quantity > self._config.max_order_quantity:
            raise OrderValidationError(
                f"Quantity exceeds the max of "
                f"{self._config.max_order_quantity:g}."
            )
        if order_type == OrderType.LIMIT:
            if price is None or price <= 0:
                raise OrderValidationError(
                    "Limit orders require a positive price."
                )
        # Estimated value (limit uses price; market has no known price yet).
        est_price = price if price else 0.0
        est_value = est_price * quantity
        if est_value > self._config.max_order_value:
            raise OrderValidationError(
                f"Estimated order value {est_value:g} exceeds the max of "
                f"{self._config.max_order_value:g}."
            )
        if order_type == OrderType.MARKET:
            warnings.append(
                "Market order: fill price is not guaranteed; value is estimated "
                "at submission."
            )
        if self._config.is_real:
            warnings.append(REAL_WARNING)
        return code, est_value, warnings

    # -- confirmation token ----------------------------------------------

    def _order_signature(
        self, symbol, market, side, quantity, order_type, price
    ) -> str:
        raw = "|".join([
            symbol.upper(), market.value, side.value, f"{quantity:g}",
            order_type.value, f"{price or 0:g}", self._config.trading_env_label,
        ])
        return raw

    def _make_token(self, signature: str, issued_at: float) -> str:
        # Use the SAME integer second everywhere (truncate once) so signing and
        # verification agree regardless of the subsecond fraction.
        issued_int = int(issued_at)
        msg = f"{signature}|{issued_int}".encode()
        digest = hmac.new(_token_secret(), msg, hashlib.sha256).hexdigest()[:32]
        return f"{issued_int}.{digest}"

    def _verify_token(self, token: str, signature: str) -> None:
        try:
            issued_str, _ = token.split(".", 1)
            issued_at = float(issued_str)
        except (ValueError, AttributeError):
            raise OrderValidationError("Invalid confirmation token.")
        if self._clock() - issued_at > self._config.confirmation_ttl_seconds:
            raise OrderValidationError(
                "Confirmation token expired; please preview again."
            )
        expected = self._make_token(signature, issued_at)
        if not hmac.compare_digest(expected, token):
            raise OrderValidationError(
                "Confirmation token does not match the order; preview again."
            )

    # -- preview / place / orders / cancel -------------------------------

    def preview(
        self, symbol, market, side, quantity, order_type, price
    ) -> OrderPreview:
        code, est_value, warnings = self._validate(
            symbol, market, side, quantity, order_type, price
        )
        signature = self._order_signature(
            symbol, market, side, quantity, order_type, price
        )
        issued_at = self._clock()
        token = self._make_token(signature, issued_at)
        return OrderPreview(
            symbol=symbol.upper(),
            market=market,
            moomoo_code=code,
            side=side,
            quantity=quantity,
            order_type=order_type,
            price=price,
            estimated_value=round(est_value, 2),
            currency=moomoo_currency(market),
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            confirmation_token=token,
            expires_in_seconds=self._config.confirmation_ttl_seconds,
            warnings=warnings,
        )

    def place(
        self, symbol, market, side, quantity, order_type, price,
        confirmation_token,
    ) -> OrderResult:
        # Re-validate from scratch (never trust the client).
        code, _, _ = self._validate(
            symbol, market, side, quantity, order_type, price
        )
        signature = self._order_signature(
            symbol, market, side, quantity, order_type, price
        )
        if not confirmation_token:
            raise OrderValidationError(
                "Missing confirmation token; orders require explicit "
                "confirmation."
            )
        self._verify_token(confirmation_token, signature)

        # Duplicate-order guard within the configured window.
        now = self._clock()
        last = self._recent.get(signature)
        if last is not None and (now - last) < self._config.duplicate_window_seconds:
            raise OrderValidationError(
                "Duplicate order detected; please wait before retrying."
            )

        if not self._client.is_connected():
            raise BrokerError("Moomoo OpenD is not reachable; order not placed.")

        result = self._client.place_order(
            code, side.value, quantity, order_type.value, price
        )
        self._recent[signature] = now
        return OrderResult(
            order_id=str(result.get("order_id", "")),
            symbol=symbol.upper(),
            market=market,
            side=side,
            quantity=quantity,
            order_type=order_type,
            price=price,
            status=str(result.get("status", "SUBMITTED")),
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            message="Order submitted." ,
        )

    def orders(self) -> OrdersResponse:
        if not self._client.is_connected():
            return OrdersResponse(connected=False, orders=[])
        rows = self._client.list_orders()
        out = []
        for r in rows:
            side = OrderSide.BUY if str(r.get("side", "")).upper().startswith(
                "BUY"
            ) else OrderSide.SELL
            otype = (
                OrderType.MARKET
                if "MARKET" in str(r.get("order_type", "")).upper()
                else OrderType.LIMIT
            )
            out.append(OpenOrder(
                order_id=str(r.get("order_id", "")),
                symbol=str(r.get("code", "")),
                side=side,
                quantity=r.get("quantity", 0.0),
                order_type=otype,
                price=r.get("price"),
                status=str(r.get("status", "")),
                created_at=str(r.get("created_at", "")),
            ))
        return OrdersResponse(connected=True, orders=out)

    def cancel(self, order_id: str) -> CancelResult:
        if not order_id:
            raise OrderValidationError("order_id is required.")
        if not self._client.is_connected():
            raise BrokerError("Moomoo OpenD is not reachable.")
        res = self._client.cancel_order(order_id)
        return CancelResult(
            order_id=order_id,
            cancelled=bool(res.get("cancelled", False)),
            status=str(res.get("status", "")),
            message="Order cancelled." if res.get("cancelled") else "",
        )
