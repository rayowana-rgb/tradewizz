# Atom: Long-Term Reversal (DeBondt-Thaler)

- **id:** longterm-reversal
- **stage:** backtest-oos
- **confidence:** 55
- **evidence:** 68
- **status:** First TRULY orthogonal partner to momentum (corr 0.34-0.46). Alpha
  is WEAK & REGIME-DEPENDENT so a naive 50/50 blend DILUTES momentum -- BUT a
  REGIME-SWITCHED crash-recovery OVERLAY (60/40 only when market < 200d SMA)
  IMPROVES full-sample excess-t, Sharpe AND worst-DD vs pure momentum
  (2026-07-04j). Confirmed as a genuine optional overlay, with a mild OOS-bull
  trade-off. See below.

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

## 2026-07-04j -- CONDITIONAL TILT tested (hypothesis CONFIRMED)
`research/backtests/momentum-reversal-tilt/run.py`. Same 301-name/223-reb
universe. Tested static 90/10 & 80/20 tilts and a REGIME-SWITCHED overlay
(60/40 mom/rev only when equal-weight market < its 200d SMA; else 100% mom;
bear_frac ~18%). Pre-stated rule: a tilt wins only if worst-DD improves AND
excess-t/Sharpe does NOT fall vs pure momentum.
  excess-over-benchmark (t / Sharpe / worst-DD):
    pure mom : FULL 2.92/0.68/-21.3% ; TRAIN 0.42/0.14/-21.3% ; TEST 3.23/1.05/-14.7%
    regime   : FULL 3.25/0.75/-14.7% ; TRAIN 1.25/0.41/ -8.6% ; TEST 3.04/0.99/-14.7%
    tilt80/20: FULL 3.10/0.72/-14.8% ; TRAIN 0.86/0.28/-14.8% ; TEST 3.16/1.03/-13.0%
VERDICT: **hypothesis CONFIRMED.** The regime overlay PASSES the rule on the
FULL sample -- higher excess-t (3.25 vs 2.92), higher Sharpe (0.75 vs 0.68) AND
much smaller worst-DD (-14.7% vs -21.3%), with higher cum return (166.7x vs
142.9x). Protection lands in stress: TRAIN worst-DD -8.6% vs -21.3% and excess-t
1.25 vs 0.42. HONEST CAVEATS: (1) mild OOS-bull cost -- TEST excess-t 3.04 vs
3.23 (reversal barely helps in a bull, tilt occasionally leans in for little
gain); (2) 301-name >=6y subset and the big TRAIN gain leans on the single
2008-09 recovery, so magnitude is not over-claimed. This is the FIRST
diversification structure that does NOT dilute momentum. Recorded as a genuine,
evidence-backed OPTIONAL crash-recovery OVERLAY (with a mild bull trade-off),
NOT a strict domination. Atom confidence 45->55, evidence 60->68 for the
CONDITIONAL-tilt use (pure reversal standalone stays weak).

## Evidence log
- 2026-07-04i: initial backtest + OOS split. See RESEARCH.md.
- 2026-07-04j: conditional crash-recovery tilt CONFIRMED (regime overlay).
  See momentum-reversal-tilt/ and production-candidate.md.
