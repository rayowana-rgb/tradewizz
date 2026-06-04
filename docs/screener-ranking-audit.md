# Screener Ranking Quality Audit

**Date:** 2026-06-05 04:02 GMT+8
**Scope:** Audit only. No code changed. Diagnoses why `/v1/screen/IDX?limit=20`
returns many illiquid small-caps all tied at **score 86**, and proposes minimal
fixes.

## 1. Reproduction (live data, IDX universe = 956)

`GET /v1/screen/IDX?limit=20` → **all 20 rows have score 86.0.** Tie-break is
`change_percent desc`, so the "ranking" within the cluster is just today's % move
(an OMRE at −14.65% sits in the top 20). Score distribution of the returned 20:
`{86.0: 20}`.

Per-symbol probe (engine fetch → `compute_all` → `categorize` → `_signal_and_score`):

| Symbol | Score | Signal | Close | value_traded (IDR) | volR | Categories |
| ------ | ----- | ------ | ----- | ------------------ | ---- | ---------- |
| DNET   | 86.0  | BUY  | 10,075 | **63,472,500** (63M) | 0.36 | bullish, scalping |
| FORU   | 86.0  | BUY  | 1,545  | **243,337,500** (243M) | 0.58 | bullish, scalping |
| MGLV   | 86.0  | BUY  | 8,175  | 2,463,945,000 (2.5B) | 1.50 | bullish, scalping |
| BLTZ   | 86.0  | BUY  | 2,890  | **0** (no volume) | 0.00 | bullish |
| GDYR   | 14.0  | SELL | 1,085  | 289,695,000 (290M) | 7.02 | bearish |
| BBCA   | 20.0  | SELL | 5,425  | 2,984,072,787,500 (2.98T) | 2.36 | bearish, frequently_traded |
| BBRI   | 14.0  | SELL | 2,810  | 1,386,595,905,000 (1.39T) | 1.95 | bearish |
| BMRI   | 14.0  | SELL | 3,970  | 1,304,262,115,000 (1.30T) | 1.47 | bearish |

Two quality problems are visible immediately:

- **DNET, FORU, BLTZ** (illiquid: 63M / 243M / **0** IDR turnover) rank in the
  top 20, while **BBCA/BBRI/BMRI** (1.3–3.0 **trillion** IDR turnover) are pushed
  to SELL/bottom purely because they're currently in a downtrend.
- **BLTZ has value_traded = 0** (no trading) yet still scores 86 and ranks above
  every blue chip.

## 2. Root cause of the identical 86

`_signal_and_score` (engine.py) builds the score from a base of 50 plus a tiny
set of **fixed discrete increments**:

```
score = 50
  ± 12  EMA20 vs EMA50
  ± 10  Close vs SMA200
  ±  8  MACD histogram sign
  +  6  RSI < 30   /   − 6  RSI > 70   (else 0)
  +  6  if bullish category
  −  6  if bearish category
```

Because the increments are constant, the score is **quantized**: only **33
distinct values** are even reachable across the whole 0–100 range
(`[8, 14, 20, 24, 26, …, 80, 86, 92]`).

`86 = 50 + 12 + 10 + 8 + 6` — i.e. **EMA20>EMA50, Close>SMA200, MACD hist > 0,
and bullish, with RSI in the normal 30–70 band.** This is the single most common
state for any stock in a mild uptrend, so a large fraction of the universe lands
on *exactly* 86. Decomposition confirms every top name is the identical bucket:

```
DNET: 86 = base(50) ema20>ema50(+12) close>sma200(+10) macd_hist>0(+8) bullish(+6)  rsi=57.2
FORU: 86 = …same…                                                                    rsi=60.6
MGLV: 86 = …same…                                                                    rsi=65.3
BLTZ: 86 = …same…                                                                    rsi=64.3
```

The `bullish` category itself requires `EMA20>EMA50 and Close>EMA20`, which is
highly correlated with the +12/+10/+8 terms — so the four bullish increments
almost always fire together, collapsing every uptrending stock to 86. There is
**no continuous term** (magnitude of trend, RSI level, volume, volatility) to
break ties, so dozens of names share the maximum.

## 3. Comparison vs migrated bot9 logic

The legacy bot did **not** use this step-sum at all for ranking:

- **Continuous, volume-weighted score** (`bot9.py:589`):
  ```
  bullish_score = (RSI-70) * (SMA50-SMA200) * (MACD-MACD_Signal) * (Volume/Volume_Avg)
  ```
  A product of magnitudes → effectively unique per stock and **scaled by relative
  volume**, so liquid/strong movers naturally rank higher. Ties at a round number
  were essentially impossible.
- **Hard liquidity gate on every strategy** (`bot9.py:882`):
  ```
  MIN_VALUE_IDR = 2_000_000_000   # 2 billion IDR
  if nominal_value < MIN_VALUE_IDR:  skip   # general filter
  ```
  DNET (63M), FORU (243M), and BLTZ (0) would **all have been filtered out**
  before scoring. The current backend has no such universe-level filter.

So two legacy behaviors were lost in migration: the **continuous volume-weighted
score** and the **2B IDR liquidity floor**.

## 4. Are liquidity / volume / frequently_traded actually affecting ranking?

**No — not the ranking.**

- `value_traded` is computed and used only **inside category gates** (e.g.
  `accumulation` needs ≥10B, `ara_hunter` ≥5B, `frequently_traded` needs
  `>20d-mean×2 AND >10B`). It is **never** part of `_signal_and_score` nor the
  `_finalize` sort key.
- `volume_ratio` likewise only feeds category gates, not the score.
- `frequently_traded` is a *tag*, not a *filter*: BBCA earns it but is still
  ranked last because its score (20) reflects only its downtrend.
- `_finalize` sorts by `key=(score, change_percent)` only. With score constant
  at 86, **change_percent is the sole tiebreaker** — which is why a −14.65%
  name (OMRE) appears in the "top" results.

Net: an untraded shell (BLTZ, value_traded=0) and a 63M micro-cap (DNET)
outrank Indonesia's largest banks.

## 5. Proposed minimal fixes (NOT applied)

Ranked by value ÷ risk. Each is small and localized to `engine.py`.

**Fix A — add a continuous tie-breaker to the sort (lowest risk, no score
change).** Change `_finalize`'s sort key from `(score, change_percent)` to
`(score, value_traded, change_percent)` (descending), so within a score cluster
the most-liquid names rank first. Tiny, reversible, doesn't alter scores or
signals; immediately surfaces BBCA-class names above shells.
*Requires `value_traded` to be carried onto `ScreenerMatch` (currently it is not
a field) — or sort using a captured liquidity value. Minor model addition.*

**Fix B — restore the legacy liquidity floor as an optional screen filter.**
Add a `min_value_traded` query param (default e.g. 2B IDR for IDX, scaled per
market via the existing `_value_floor`) applied in `_finalize` like `min_score`.
Drops untraded/illiquid names (BLTZ=0, DNET=63M) from results entirely. Opt-in
keeps it contract-safe.

**Fix C — de-quantize the score with a small continuous component (higher
risk).** Add a bounded continuous term so ties break on real strength, e.g. a
few points scaled by `tanh`-normalized `(macd - macd_signal)`, RSI distance from
50, and/or `log(volume_ratio)`. Keeps the 0–100 range and BUY/HOLD/SELL bands
but spreads the 86-cluster. This changes scores broadly, so it needs its own
test pass — defer unless A+B prove insufficient.

**Recommended first step:** **A + B together** (continuous liquidity tiebreaker +
optional liquidity floor). Both are minimal, low-risk, reversible, and directly
fix the observed symptom (illiquid names dominating, blue chips buried) without
reworking the scoring model. C is the deeper fix but should be a separate,
test-backed change.

## 6. Evidence summary

- Identical 86 = constant step-sum quantization (only 33 reachable scores);
  every uptrending stock hits the same `+12+10+8+6` bucket.
- Liquidity/volume influence **category tags only**, never score or sort order.
- Tie-break is `change_percent`, so % move (even large losses) decides the "top".
- Legacy used a continuous volume-weighted score **and** a 2B IDR liquidity gate;
  both were dropped in migration.
- Examples confirm the failure: BLTZ (0 turnover) and DNET (63M) rank above
  BBCA/BBRI/BMRI (1.3–3.0T turnover).
