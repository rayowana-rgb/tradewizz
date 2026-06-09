"""Portfolio Rebalancing AI (Phase 3).

Rule-based ADD / HOLD / REDUCE / EXIT suggestions over the SIMULATED portfolio.
Reuses Portfolio Health (quality scores), the existing engine score per symbol,
current simulated allocation, and the per-market regime from the Radar. No LLM,
no broker contact, no accounting changes. All buy/sell follow-through uses the
simulation order ticket only.
"""
