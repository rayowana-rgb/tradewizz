"""IBKR service: validation + confirmation tokens + risk controls.

Mirrors the Moomoo BrokerService safety model exactly:
- preview NEVER places; place REQUIRES a matching, unexpired confirmation token;
- unsupported symbols/markets fail clearly;
- order value/quantity caps; duplicate-order guard;
- paper by default; real only when explicitly configured (loud warning).
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
import threading
import time
from typing import Dict, Optional

from ..broker.models import (
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
from ..models import Market
from .ibkr_client import (
    IBKRClient,
    IBKRClientIdInUseError,
    IBKRConnectionError,
    IBKRError,
    IBKRInsufficientFundsError,
    IBKRReadOnlyError,
    MockIBKRClient,
)

READ_ONLY_NOTE = (
    "IB Gateway is in Read-Only API mode; order requests are unavailable. "
    "Account and positions are unaffected."
)

# Clear, user-facing message when Read-Only API mode blocks an order. Surfaced
# verbatim to the app instead of a generic 'Order failed'.
READ_ONLY_ORDER_MESSAGE = (
    "IB Gateway is currently running in Read-Only API mode. "
    "Disable Read-Only to place orders."
)
from .ibkr_config import IBKRConfig
from .ibkr_symbols import IBKRSymbolNotTradable, to_ibkr_contract

logger = logging.getLogger("tradewizz.ibkr")

REAL_WARNING = (
    "REAL IBKR TRADING ENABLED — orders use real money. Every order still "
    "requires explicit confirmation."
)


class IBKROrderValidationError(Exception):
    def __init__(self, message: str, status_code: int = 400):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


def _token_secret() -> bytes:
    return os.environ.get(
        "TRADEWIZZ_ORDER_TOKEN_SECRET", "tradewizz-dev-secret"
    ).encode()


class IBKRService:
    def __init__(
        self,
        config: Optional[IBKRConfig] = None,
        client=None,
        clock=time.time,
    ):
        self._config = config or IBKRConfig.from_env()
        self._client = client or IBKRClient(self._config)
        self._clock = clock
        self._recent: Dict[str, float] = {}
        # Diagnostics (req 2): prove every path uses the current config and see
        # the service/client identity + process/thread that built it.
        logger.info(
            "IBKRService created host=%s port=%s client_id=%s env=%s "
            "pid=%s thread=%s service_obj=0x%x client_obj=0x%x",
            self._config.host, self._config.port, self._config.client_id,
            self._config.trading_env_label, os.getpid(),
            threading.current_thread().name, id(self), id(self._client),
        )

    @property
    def config(self) -> IBKRConfig:
        return self._config

    # -- status / account / positions ------------------------------------

    def status(self) -> BrokerStatus:
        try:
            connected = self._client.is_connected()
        except Exception as exc:  # noqa: BLE001
            logger.warning("IBKR status check failed: %s", exc)
            connected = False
        return BrokerStatus(
            connected=connected,
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            host=self._config.host,
            port=self._config.port,
            client_id=self._config.client_id,
            warning=REAL_WARNING if self._config.is_real else None,
            message=("Connected to IB Gateway" if connected
                     else "IB Gateway not reachable"),
        )

    def account(self) -> AccountSummary:
        # Attempt the real account summary directly. We deliberately do NOT
        # pre-probe with a separate is_connected() connect: against a live IB
        # Gateway, two back-to-back connects on the same clientId race (the
        # first disconnect overlaps the second connect), which intermittently
        # made this report connected=False -> a false 'IBKR is not reachable'
        # error in the portfolio even though accountSummary works. connected
        # is derived from whether the fetch itself succeeds.
        try:
            d = self._client.account_summary()
        except IBKRError as exc:
            logger.warning("IBKR account_summary failed: %s", exc)
            return AccountSummary(
                connected=False, trading_env=self._config.trading_env_label
            )
        return AccountSummary(
            connected=True,
            currency=d.get("currency", ""),
            cash=d.get("cash", 0.0),
            buying_power=d.get("buying_power", 0.0),
            total_assets=d.get("total_assets", 0.0),
            trading_env=self._config.trading_env_label,
        )

    def positions(self) -> PositionsResponse:
        # Fetch positions directly; derive connected from success (no redundant
        # is_connected() pre-probe — see account() for the rationale).
        try:
            rows = self._client.positions()
        except IBKRError as exc:
            logger.warning("IBKR positions failed: %s", exc)
            return PositionsResponse(connected=False, positions=[])
        out = []
        for r in rows:
            # US positions are the common case; market is best-effort.
            market = Market.HKEX if r.get("currency") == "HKD" else Market.IDX
            out.append(Position(
                symbol=str(r.get("symbol", "")),
                market=market,
                quantity=r.get("quantity", 0.0),
                cost_price=r.get("cost_price", 0.0),
                current_price=0.0,
                market_value=float(r.get("quantity", 0) or 0)
                * float(r.get("cost_price", 0) or 0),
                pl_value=0.0,
            ))
        return PositionsResponse(connected=True, positions=out)

    # -- validation / token (same scheme as Moomoo) ----------------------

    def _resolve(self, symbol: str, market: Market) -> dict:
        try:
            return to_ibkr_contract(symbol, market)
        except IBKRSymbolNotTradable as exc:
            raise IBKROrderValidationError(exc.message) from exc

    def _validate(self, symbol, market, side, quantity, order_type, price):
        spec = self._resolve(symbol, market)
        warnings = []
        if quantity <= 0:
            raise IBKROrderValidationError("Quantity must be > 0.")
        if quantity > self._config.max_order_quantity:
            raise IBKROrderValidationError(
                f"Quantity exceeds the max of "
                f"{self._config.max_order_quantity:g}."
            )
        if order_type == OrderType.LIMIT and (price is None or price <= 0):
            raise IBKROrderValidationError(
                "Limit orders require a positive price."
            )
        est_value = (price or 0.0) * quantity
        if est_value > self._config.max_order_value:
            raise IBKROrderValidationError(
                f"Estimated order value {est_value:g} exceeds the max of "
                f"{self._config.max_order_value:g}."
            )
        if order_type == OrderType.MARKET:
            warnings.append("Market order: fill price is not guaranteed.")
        if self._config.is_real:
            warnings.append(REAL_WARNING)
        return spec, est_value, warnings

    @staticmethod
    def _market_label(market) -> str:
        # US stocks have no TradeWizz Market enum -> 'US'.
        return market.value if market is not None else "US"

    def _signature(self, symbol, market, side, quantity, order_type, price):
        return "|".join([
            "IBKR", symbol.upper(), self._market_label(market), side.value,
            f"{quantity:g}", order_type.value, f"{price or 0:g}",
            self._config.trading_env_label,
        ])

    def _make_token(self, signature: str, issued_at: float) -> str:
        issued_int = int(issued_at)
        msg = f"{signature}|{issued_int}".encode()
        digest = hmac.new(_token_secret(), msg, hashlib.sha256).hexdigest()[:32]
        return f"{issued_int}.{digest}"

    def _verify_token(self, token: str, signature: str) -> None:
        try:
            issued_str, _ = token.split(".", 1)
            issued_at = float(issued_str)
        except (ValueError, AttributeError):
            raise IBKROrderValidationError("Invalid confirmation token.")
        if self._clock() - issued_at > self._config.confirmation_ttl_seconds:
            raise IBKROrderValidationError(
                "Confirmation token expired; please preview again."
            )
        if not hmac.compare_digest(
            self._make_token(signature, issued_at), token
        ):
            raise IBKROrderValidationError(
                "Confirmation token does not match the order; preview again."
            )

    # -- preview / place / orders / cancel -------------------------------

    def preview(self, symbol, market, side, quantity, order_type, price,
                user_id=None):
        logger.info(
            "order-preview broker=IBKR symbol=%s market=%s side=%s qty=%s "
            "type=%s price=%s user=%s env=%s",
            symbol, self._market_label(market), side.value, quantity,
            order_type.value, price, user_id, self._config.trading_env_label,
        )
        spec, est_value, warnings = self._validate(
            symbol, market, side, quantity, order_type, price
        )
        signature = self._signature(
            symbol, market, side, quantity, order_type, price
        )
        issued_at = self._clock()
        # OrderPreview.market is required; HKEX covers SEHK, US maps to a
        # representable default (no US enum yet) — the moomoo_code carries the
        # real exchange.
        model_market = market if market is not None else Market.HKEX
        return OrderPreview(
            symbol=symbol.upper(),
            market=model_market,
            moomoo_code=f"{spec['exchange']}:{spec['symbol']}",
            side=side,
            quantity=quantity,
            order_type=order_type,
            price=price,
            estimated_value=round(est_value, 2),
            currency=spec["currency"],
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            confirmation_token=self._make_token(signature, issued_at),
            expires_in_seconds=self._config.confirmation_ttl_seconds,
            warnings=warnings,
        )

    def place(self, symbol, market, side, quantity, order_type, price,
              confirmation_token, user_id=None):
        spec, _, _ = self._validate(
            symbol, market, side, quantity, order_type, price
        )
        signature = self._signature(
            symbol, market, side, quantity, order_type, price
        )
        # Structured per-attempt diagnostics: broker, symbol, side, qty, type,
        # price, user, token status, then preview/IBKR result below.
        token_status = "present" if confirmation_token else "missing"
        logger.info(
            "order-attempt broker=IBKR symbol=%s market=%s side=%s qty=%s "
            "type=%s price=%s user=%s env=%s token=%s",
            symbol, self._market_label(market), side.value, quantity,
            order_type.value, price, user_id, self._config.trading_env_label,
            token_status,
        )
        if not confirmation_token:
            raise IBKROrderValidationError(
                "Missing confirmation token; orders require explicit "
                "confirmation."
            )
        self._verify_token(confirmation_token, signature)

        now = self._clock()
        last = self._recent.get(signature)
        if last is not None and (now - last) < self._config.duplicate_window_seconds:
            raise IBKROrderValidationError(
                "Duplicate order detected; please wait before retrying."
            )
        # Place directly. place_order opens a single ib_insync connection (no
        # raw-socket pre-flight, no redundant is_connected() connect that used
        # to triple-connect and race the clientId -> generic 502). Each failure
        # mode is surfaced as a specific, typed error below.
        try:
            result = self._client.place_order(
                spec, side.value, quantity, order_type.value, price
            )
        except IBKRReadOnlyError as exc:
            # Read-Only API mode blocks transmit even though connect succeeded.
            logger.warning("order-reject broker=IBKR reason=read-only user=%s",
                           user_id)
            raise IBKROrderValidationError(
                READ_ONLY_ORDER_MESSAGE, status_code=409
            ) from exc
        except IBKRInsufficientFundsError as exc:
            logger.warning(
                "order-reject broker=IBKR reason=insufficient-funds user=%s",
                user_id,
            )
            raise IBKROrderValidationError(
                "Insufficient buying power to place this order.",
                status_code=400,
            ) from exc
        except IBKRClientIdInUseError as exc:
            logger.warning(
                "order-reject broker=IBKR reason=client-id-in-use user=%s",
                user_id,
            )
            # 409 conflict: another API session holds the clientId.
            raise IBKROrderValidationError(str(exc), status_code=409) from exc
        except IBKRConnectionError as exc:
            # Clear, specific 502 reason (timeout / refused) — never the generic
            # 'IB Gateway is not reachable; order not placed.'
            logger.warning(
                "order-reject broker=IBKR reason=connection user=%s detail=%s",
                user_id, exc,
            )
            raise IBKRError(str(exc)) from exc
        self._recent[signature] = now
        logger.info(
            "order-result broker=IBKR symbol=%s order_id=%s status=%s user=%s",
            symbol, result.get("order_id", ""), result.get("status", ""),
            user_id,
        )
        return OrderResult(
            order_id=str(result.get("order_id", "")),
            symbol=symbol.upper(),
            market=market if market is not None else Market.HKEX,
            side=side,
            quantity=quantity,
            order_type=order_type,
            price=price,
            status=str(result.get("status", "SUBMITTED")),
            trading_env=self._config.trading_env_label,
            is_real=self._config.is_real,
            message="Order submitted.",
        )

    def orders(self) -> OrdersResponse:
        if not self._client.is_connected():
            return OrdersResponse(connected=False, orders=[])
        try:
            rows = self._client.orders()
        except IBKRReadOnlyError:
            # Read-Only API mode blocks order requests but the broker is still
            # connected (account/positions work). Do NOT mark disconnected.
            logger.info("IBKR orders blocked by Read-Only API mode.")
            return OrdersResponse(connected=True, orders=[],
                                  note=READ_ONLY_NOTE)
        out = []
        for r in rows:
            side = OrderSide.BUY if str(r.get("side", "")).upper().startswith(
                "BUY"
            ) else OrderSide.SELL
            otype = (OrderType.MARKET
                     if "MKT" in str(r.get("order_type", "")).upper()
                     or "MARKET" in str(r.get("order_type", "")).upper()
                     else OrderType.LIMIT)
            out.append(OpenOrder(
                order_id=str(r.get("order_id", "")),
                symbol=str(r.get("symbol", "")),
                side=side,
                quantity=r.get("quantity", 0.0),
                order_type=otype,
                price=r.get("price"),
                status=str(r.get("status", "")),
            ))
        return OrdersResponse(connected=True, orders=out)

    def cancel(self, order_id: str) -> CancelResult:
        if not order_id:
            raise IBKROrderValidationError("order_id is required.")
        if not self._client.is_connected():
            raise IBKRError("IB Gateway is not reachable.")
        res = self._client.cancel_order(order_id)
        return CancelResult(
            order_id=order_id,
            cancelled=bool(res.get("cancelled", False)),
            status=str(res.get("status", "")),
            message="Order cancelled." if res.get("cancelled") else "",
        )
