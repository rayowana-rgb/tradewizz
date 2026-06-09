"""Auto Watchlist AI (Phase 3).

Rule-based daily watchlist suggestions derived from the existing Opportunity
Radar / Daily Picks / Multibagger Finder. Suggestions are read-only; applying a
suggestion records server-side source metadata + emits a notification, while the
client adds the symbol to its (client-side) watchlist. Research only.
"""
