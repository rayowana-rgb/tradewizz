# Atom: Long-Term Reversal (DeBondt-Thaler)

- **id:** longterm-reversal
- **stage:** backtest-oos
- **confidence:** 45
- **evidence:** 60
- **status:** First TRULY orthogonal partner to momentum (corr 0.34-0.46), but
  alpha is WEAK & REGIME-DEPENDENT; a naive 50/50 blend DILUTES momentum.
  Retained as a candidate CONDITIONAL (crash-recovery) hedge, not a steady blend.

## Claim (tested)
Going long the multi-year LOSERS (lowest ~5y return, skipping the last 12 months
to avoid momentum overlap), long-only top-10 monthly, (1) carries alpha and
(2) is low/negatively correlated with 12-1 momentum, so a blend lifts the
portfolio (the decorrelation partner we've been hunting for).

## Verdict
- Orthogonality: **CONFIRMED.** corr(12-1, reversal) = 0.34 (TEST) / 0.46 (FULL)
  -- far below 6-1 (0.87) and residual (0.91). Books share only ~1.4/10 names.
  This is the genuine structural decorrelation earlier partners lacked.
- Alpha: **WEAK & REGIME-DEPENDENT.** Standalone reversal excess-over-benchmark
  is positive-ish in TRAIN (t 1.66, GFC-era snap-back) but ~ZERO in TEST
  (t 0.28, 2017+ bull). Not a steady alpha; concentrated in post-crash recovery.
- Blend: **DOES NOT beat momentum.** Because reversal is the weaker signal, the
  50/50 blend excess-t (2.81 FULL / 2.38 TEST) is BELOW pure momentum (2.92 /
  3.23) and Sharpe drops (TEST 0.78 vs 1.05). Great decorrelation, but mixing in
  a weaker mean at 50% sacrifices too much return.

## Measured (2026-07-04i; real, not fabricated)
`research/backtests/longterm-reversal/run.py`. Universe restricted to names with
>=6y history: 301 symbols, avg ~243 tradable/rebalance, 223 rebalances, top-10/
monthly/no-stop, net 10bps. TRAIN<2017 / TEST>=2017. (Not directly comparable to
343-name runs; compare within this run.)
  excess-over-benchmark t -- 12-1 / reversal / blend:
    FULL  2.92 / 1.20 / 2.81
    TRAIN 0.42 / 1.66 / 1.50
    TEST  3.23 / 0.28 / 2.38
  excess Sharpe -- FULL 0.68/0.28/0.65 ; TEST 1.05/0.09/0.78
  corr(12-1, reversal) 0.34-0.66 ; name overlap ~1.4/10.

## Retained knowledge
- Reversal is the FIRST partner with real low correlation to momentum (0.34-0.46)
  -- the decorrelation structure is finally there. The reason earlier blends
  failed to lift was HIGH correlation; the reason THIS one fails is a WEAK,
  regime-dependent partner alpha. Two distinct failure modes, both recorded.
- Notable pattern: reversal is strongest in TRAIN (GFC recovery, t 1.66) exactly
  when momentum is WEAKEST (TRAIN excess t 0.42). => a CONDITIONAL / crash-
  recovery tilt (e.g. 80/20 momentum/reversal, or regime-switched) MIGHT add
  drawdown resilience without much return give-up. This is a HYPOTHESIS ONLY --
  NOT tested here; do not claim it works until a weighted/regime-switched
  backtest is run.

## Evidence log
- 2026-07-04i: initial backtest + OOS split. See RESEARCH.md.
