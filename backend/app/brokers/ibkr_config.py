"""IBKR (Interactive Brokers) configuration from environment.

Paper by default. Live only when TRADEWIZZ_IBKR_TRADING_ENV=live AND a live
port is configured. No secrets in source.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


def _i(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class IBKRConfig:
    host: str = "127.0.0.1"
    port: int = 7497  # paper TWS/Gateway default (live is usually 7496)
    client_id: int = 21
    account: str = ""
    trading_env: str = "paper"
    connect_timeout: float = 4.0
    # Risk caps (mirror the Moomoo defaults; in account currency).
    max_order_value: float = 100_000.0
    max_order_quantity: float = 100_000.0
    confirmation_ttl_seconds: float = 120.0
    duplicate_window_seconds: float = 30.0

    @property
    def is_real(self) -> bool:
        return self.trading_env.strip().lower() in ("real", "live")

    @property
    def trading_env_label(self) -> str:
        return "REAL" if self.is_real else "PAPER"

    @classmethod
    def from_env(cls) -> "IBKRConfig":
        return cls(
            host=os.environ.get("TRADEWIZZ_IBKR_HOST", "127.0.0.1"),
            port=_i("TRADEWIZZ_IBKR_PORT", 7497),
            client_id=_i("TRADEWIZZ_IBKR_CLIENT_ID", 21),
            account=os.environ.get("TRADEWIZZ_IBKR_ACCOUNT", ""),
            trading_env=os.environ.get("TRADEWIZZ_IBKR_TRADING_ENV", "paper"),
        )
