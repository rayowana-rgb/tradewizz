# Atom: Low-Volatility (long-only, unlevered) — REJECTED standalone

- **id:** low-volatility
- **stage:** backtest-oos
- **confidence:** 30
- **evidence:** 55
- **status:** REJECTED as a standalone long-only alpha; retained as KNOWLEDGE.

## Claim (tested)
Selecting the top-10 US names with the LOWEST trailing 63-day daily-return
volatility, held long-only equal-weight monthly, earns a positive
excess-over-benchmark return (the classic "low-volatility anomaly").

## Verdict: FALSE in this setting
In a long-only, unlevered, equal-weight book on the tradable US universe
(343 names, 231 rebalances, 2007–2026, net 10bps/side), low-vol UNDERPERFORMS
the equal-weight benchmark on return:

- FULL excess: -1.13%/hold, t **-3.42** (significantly NEGATIVE), cum -0.95
- TRAIN excess: -0.66%/hold, t -1.61
- TEST excess: -1.63%/hold, t **-3.12** (significantly NEGATIVE)

Its stand-alone Sharpe (0.63–0.80) looks acceptable ONLY because its return
volatility is low — but on realised RETURN it loses to simply holding the market.

## Why (mechanism / literature)
The academic low-vol "anomaly" (Baker-Bradley-Wurgler; Frazzini-Pedersen BAB)
delivers its edge via a LONG-low-beta / SHORT-high-beta construction, often
LEVERED up to market beta. We have neither shorting nor leverage here, so we
capture only the low-return low-beta leg and give up the market's equity premium.
Low-vol is a RISK-REDUCTION tool, not a long-only return enhancer.

## Retained knowledge (do not discard)
1. Low-vol is roughly ORTHOGONAL to momentum: corr(mom, low-vol) 0.24–0.49
   across splits. The decorrelation MECHANISM is real and reusable.
2. A 50/50 momentum+low-vol blend DID raise ABSOLUTE Sharpe above both single
   books (FULL 0.97 vs 0.92/0.72; TEST 1.12 vs 1.09/0.63) — diversification
   works as theory predicts.
3. BUT because low-vol has no standalone alpha, the blend DILUTES momentum's
   significant edge: blend excess-t falls to 1.06 (FULL) / 1.30 (TEST), below
   the t>=2 bar momentum clears alone. => low-vol is the WRONG blend partner in
   a long-only unlevered book; a partner with real alpha (value / quality) is
   needed to convert the decorrelation into a HIGHER-significance combined edge.

## Evidence log
- 2026-07-04f: `research/backtests/momentum-lowvol-combo/run.py`. See combo
  finding in `momentum-long-only.md` and RESEARCH.md. Confidence 30 (rejected
  as standalone alpha), evidence 55 (well-measured across 20y + OOS; the
  NEGATIVE result is robust).
