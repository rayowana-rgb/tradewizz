"""Broker (Moomoo OpenD) configuration from environment variables.

No secrets in source. Credentials/connection come from env only; the password,
if any, never leaves the backend and is never returned to Flutter.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _f(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


def _i(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class BrokerConfig:
    # OpenD local gateway.
    host: str = "127.0.0.1"
    port: int = 11111
    # Trading env: "paper" (SIMULATE) by default; "real" only when explicit.
    trading_env: str = "paper"
    # Optional account id / unlock password (password stays server-side only).
    acc_id: int = 0
    trade_pwd: str = ""
    # Risk controls.
    max_order_value: float = 100_000_000.0  # in the symbol's currency
    max_order_quantity: float = 1_000_000.0
    duplicate_window_seconds: float = 30.0
    confirmation_ttl_seconds: float = 120.0

    @property
    def is_real(self) -> bool:
        return self.trading_env.strip().lower() == "real"

    @property
    def trading_env_label(self) -> str:
        return "REAL" if self.is_real else "PAPER"

    @classmethod
    def from_env(cls) -> "BrokerConfig":
        return cls(
            host=os.environ.get("TRADEWIZZ_OPEND_HOST", "127.0.0.1"),
            port=_i("TRADEWIZZ_OPEND_PORT", 11111),
            trading_env=os.environ.get("TRADEWIZZ_TRADING_ENV", "paper"),
            acc_id=_i("TRADEWIZZ_MOOMOO_ACC_ID", 0),
            trade_pwd=os.environ.get("TRADEWIZZ_MOOMOO_TRADE_PWD", ""),
            max_order_value=_f("TRADEWIZZ_MAX_ORDER_VALUE", 100_000_000.0),
            max_order_quantity=_f("TRADEWIZZ_MAX_ORDER_QTY", 1_000_000.0),
            duplicate_window_seconds=_f("TRADEWIZZ_DUP_WINDOW_SECONDS", 30.0),
            confirmation_ttl_seconds=_f("TRADEWIZZ_CONFIRM_TTL_SECONDS", 120.0),
        )
