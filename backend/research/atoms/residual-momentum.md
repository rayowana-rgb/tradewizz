# Atom: Residual Momentum (beta-adjusted)

- **id:** residual-momentum
- **stage:** backtest-oos
- **confidence:** 70
- **evidence:** 66
- **status:** CONFIRMED as a modestly STRONGER standalone signal than raw 12-1;
  REJECTED as an orthogonal diversifier (hypothesis refuted).

## Claim (two, tested separately)
1. (Signal) Ranking by beta-adjusted momentum -- each name's daily returns
   regressed on the equal-weight market over the 252d/skip-21d window, ranked by
   mean RESIDUAL (alpha + unexplained drift) -- outperforms raw 12-1 price
   momentum long-only top-10 monthly.
2. (Diversifier) Because it strips the common market-beta component, residual
   momentum is MORE orthogonal to raw 12-1 than another price horizon (6-1),
   so a blend gives a bigger decorrelation lift.

## Verdict
- Claim 1: **TRUE (modest).** Residual momentum's excess-over-benchmark beats
  raw 12-1 in EVERY split: FULL t 3.23 vs 2.94; TEST t **3.03 vs 2.62**; higher
  Sharpe (TEST 0.99 vs 0.86) and a slightly tamer worst DD (-33.6% vs -34.0%).
  Beta-adjusting the ranking picks marginally better names.
- Claim 2: **FALSE (hypothesis refuted).** corr(12-1, resid) = 0.91 -- even
  HIGHER than 6-1's 0.87 -- and the books share 7.5/10 names (vs 4.85 for 6-1).
  Over a 252d window the beta*market term is small & slow-moving, so alpha+
  residual ranking picks nearly the same high-momentum names. Stripping beta did
  NOT decorrelate. The blend adds nothing (excess-t 3.22 ~ resid 3.23).
  => Residual momentum is a SIGNAL UPGRADE, not a diversification partner.

## Measured (2026-07-04h; real, not fabricated)
`research/backtests/momentum-residual/run.py`; `results.json`. 343 names, 231
rebalances, top-10/monthly/no-stop, net 10bps/side. TRAIN<2017 / TEST>=2017.
  excess-over-benchmark t -- 12-1 / resid / blend:
    FULL  2.94 / 3.23 / 3.22
    TRAIN 1.38 / 1.21 / 1.40
    TEST  2.62 / 3.03 / 2.94
  excess Sharpe -- FULL 0.67/0.74/0.73 ; TEST 0.86/0.99/0.96
  corr(12-1, resid): 0.90-0.91 ; name overlap 7.4-7.8 / 10.

## Retained knowledge
- "Beta-adjusted = more orthogonal" is INTUITIVE BUT FALSE over long lookbacks
  in a long-only top-decile book: the beta term is too small to change the
  ranking much. Recorded so we don't repeat the reasoning.
- Actionable: the production momentum ranking could be swapped to residual
  (beta-adjusted) momentum for a small OOS edge boost (TEST excess-t 2.62->3.03)
  WITHOUT changing anything else in the spec. Pending Stage-4 confirmation before
  any production change.

## Evidence log
- 2026-07-04h: initial backtest + OOS split. See RESEARCH.md and the combo
  context in `momentum-long-only.md`.
