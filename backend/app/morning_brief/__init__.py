"""AI Morning Brief — a rule-based, once-per-session market summary.

Reuses the existing Opportunity Radar (screener + ranking + market regime) and
a lightweight sector classifier to produce a plain-language brief per market.
No LLM, no new scoring/indicators, no broker contact.
"""
