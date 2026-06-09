"""Community demand analytics (Phase 2/E).

A thin admin/analytics view over the existing usage-event store: which preview
features are opened most. Reuses the subscription service's demand breakdown;
adds no new storage. No PII beyond user-id counts.
"""
