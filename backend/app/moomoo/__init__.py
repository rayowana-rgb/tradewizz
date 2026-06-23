"""Private, single-user Moomoo LIVE trading bridge.

This package is NOT part of the public TradeWizz product. It exposes a thin,
heavily guard-railed bridge from the owner's app to a local Moomoo OpenD
gateway so the owner can place real US orders from their own build.

Access is gated by (1) a JWT belonging to an explicit owner allowlist and
(2) an environment secret. Live order placement additionally requires a
two-step preview -> confirm and respects a hard per-order notional cap and a
kill-switch env var.
"""
