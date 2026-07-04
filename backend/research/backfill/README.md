# Multi-year history backfill — assessment & plan

**Date:** 2026-07-04
**Status:** feasibility CONFIRMED; script ready; **NOT yet run** (bulk Yahoo
fetch awaits explicit go-ahead).

## Why this, before any new atom
Every fragile-signal research question is currently blocked by the same root
cause: the live cache is **~1 year, a single market regime**. Concretely this
caps:
- **Momentum 12-1** (needs ~278 trading days; we have ~251 common) — untestable.
- **Momentum crashes** (Daniel-Moskowitz) — only ONE crash date (2026-03-27) in
  sample; cannot calibrate a crash defense on n=1.
- **Regime-guard calibration** — only 7 rebalances survived the 100d warm-up;
  the naive gate was rejected largely for lack of data.
- **Evidence ceiling** — the pipeline caps evidence at ~55 for single-regime
  results, on purpose. No amount of cleverness lifts it; only more history does.

So the highest-leverage next step is infrastructure (data), not a new concept.

## Feasibility (verified, 2026-07-04)
Single probe via the backend fetch path (`app.engine._yf_fetch`,
`period='max'`) returned **AAPL: 11,480 rows, 1980-12-12 .. 2026-07-02** with
the correct columns (Adj Close, Close, High, Low, Open, Volume). `yfinance`
supports `2y/5y/10y/max`. The cache is keyed by `(ticker, period, interval)`,
so a `max` entry is SEPARATE from and does NOT overwrite the existing `1y`
data.

## Scope decision — liquid sub-universe only
We do NOT backfill the full ~10,300-symbol universe:
- At the user's hard throttle (<= ~14 req / 30s) that would take ~6 hours and
  risk a rate-limit ban.
- Only **tradable** names matter for any signal (the liquidity atom already
  showed 19.3% of the universe is untradable and contaminates signals).

Instead: rank the existing 1y cache by median 63d dollar-volume, keep names
passing the tradability gate, take the **top N by ADV** (default 800). Index
symbols (`^...`) are excluded. Estimated time: **~29 min for 800 names** at
14 req / 30s + jitter. Resumable (skips already-cached `max` entries).

## Respect for constraints
- Throttle: `MAX_REQ=14`, `WINDOW_S=30`, plus 0.8s per-request jitter.
- Reuses the backend's existing 429 retry/backoff (`_with_yf_retry`).
- Read-only universe selection (no network) via `--dry-run`.
- Does not touch production code or existing cache entries.

## How to run
Dry-run (no requests):
```
PYTHONPATH=. .venv/bin/python research/backfill/backfill_liquid_history.py --dry-run --top 800
```
Real run (only after go-ahead):
```
PYTHONPATH=. .venv/bin/python research/backfill/backfill_liquid_history.py --period max --top 800
```

## After backfill — the queued research
1. Re-run cross-sectional-momentum with the true **12-1** variant (now
   possible) across multiple regimes; promote/reject on real multi-regime IC.
2. Re-run regime-guard over real drawdowns/crashes to calibrate (or finally
   reject) a crash defense.
3. Re-run short-term-momentum out-of-sample (Stage-4) to test whether the
   in-sample continuation survives — the single biggest open question.
4. Lift the evidence ceiling above ~55 for anything that replicates.
