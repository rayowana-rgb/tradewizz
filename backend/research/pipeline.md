# TradeWizz Research Pipeline — The Four-Stage Gate

> No investment concept enters the TradeWizz production engine (`backend/app/`)
> until it has passed all four stages. Every production feature must carry
> **measurable evidence** that it improves decision quality. We never optimize
> for speed. We never fabricate evidence. If a stage has not been run, its
> status is `PENDING`, not assumed.

This document is the contract. `RESEARCH.md` (repo root) is the live index of
every knowledge atom and the stage it currently occupies.

---

## The Gate

A concept is represented by a **knowledge atom** in `research/atoms/<slug>.md`.
It advances only when the current stage is fully satisfied and recorded.

### Stage 1 — Literature Review  (`status: lit`)
- Read the primary sources deeply (papers, books, exchange docs, filings).
- Extract concepts, not prose. Separate facts from opinions.
- Record: definition, theory, *why* it works, *when* it works, *when it fails*,
  strengths, weaknesses, regime, timeframe, suitable assets, risk.
- Cite real references only. **No invented citations.** If a source cannot be
  verified, mark the claim `unverified` and lower its confidence.
- Output: a complete knowledge atom with `stage: lit`, `confidence`, `evidence`.

### Stage 2 — Logical Validation  (`status: logic`)
- Is the concept internally consistent? Does the math hold?
- Is it falsifiable? Can it be expressed as explicit, testable rules
  (entry / exit / risk / sizing)?
- Is it distinct from atoms we already have, or a duplicate/contradiction?
  If it contradicts an existing atom, resolve it and update the older atom.
- Guard against look-ahead bias, survivorship bias, data-snooping in the
  proposed test design *before* running anything.
- Output: a formal rule spec in the atom + a documented test plan.

### Stage 3 — Historical Backtesting  (`status: backtest`)
- Implement the rule spec in `research/backtests/<slug>/`.
- Report the full evidence set, never a single number:
  expected value, win rate, profit factor, Sharpe, max drawdown, turnover,
  sample size, number of independent bets, and the **data window + regime**
  the result covers.
- State every limitation explicitly. Our current OHLCV depth is ~1 trading
  year (single regime) — cross-sectional/relative claims are testable now;
  long-horizon Sharpe/drawdown across regimes are **NOT** and must be marked
  `insufficient-history`.
- A result that fails is still recorded (we never discard useful knowledge).
- Output: a reproducible backtest + a results file with measured metrics.

### Stage 4 — Real-World Performance Evaluation  (`status: live-eval`)
- Paper/forward evaluation on live data before production trust.
- Compare realized outcomes to backtested expectations; measure decay.
- Requires the live app in the user's hands (TestFlight) to close the loop on
  decision-quality feedback.
- Output: an ongoing evaluation log; promotion to production only with a
  positive, measured, out-of-sample signal.

### Promotion to Production  (`status: prod`)
- Only after Stage 4 shows measurable improvement in decision quality.
- The production module must be reusable, backtestable, and explainable.
- Every production signal must be able to explain itself (see EXPLAINABILITY).

---

## Evidence & Confidence Scoring

Both scored 0–100, stored in each atom's front-matter and justified in text.

- **Confidence** — how sure we are the concept is *true / sound*, given theory
  + independent literature + internal logic.
- **Evidence** — how strong *our own measured proof* is, given the data we
  actually have. With ~1 year single-regime data, evidence is capped: a
  cross-sectional edge tested on ~1y of US equities cannot exceed ~55 until we
  have multi-regime history or live out-of-sample confirmation.

Scoring rubric (evidence):
- 0–20: theory only, untested here.
- 21–40: logically validated, no backtest yet.
- 41–55: backtested on our ~1y single-regime data (in-sample regime).
- 56–75: backtested across multiple regimes / out-of-sample.
- 76–100: confirmed by live forward evaluation.

---

## Anti-Fabrication Rules (binding)

1. Never report a metric that was not computed by a committed, re-runnable
   backtest. If it wasn't run, write `PENDING`.
2. Never cite a source you cannot name and locate.
3. Never present a fit/heuristic gauge as a probability of a return.
4. Always disclose the data window and regime behind any number.
5. Failed results are recorded, not hidden.
