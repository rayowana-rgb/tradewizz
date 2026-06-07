# Screener Scoring Parity Audit — IDX / HKEX / KOSPI / KOSDAQ

**Date:** 2026-06-07 09:40 GMT+8
**Scope:** Audit only. No code changed. Verifies the scoring pipeline and
weights are identical across all four markets.

## TL;DR

- **The score formula is market-agnostic.** `AnalysisEngine._signal_and_score`
  takes only `(ind, cats)` — **no `market` argument** — so IDX, HKEX, KOSPI, and
  KOSDAQ run the exact same scoring path with the exact same weights.
- **Indicator computation is market-agnostic.** `indicators.compute_all(df)`
  takes only the OHLCV DataFrame; every indicator (RSI/EMA/SMA/MACD/ATR/OBV/
  A-D/CMF/VWAP/ADX/volume_ratio/value_traded) is computed identically for all
  markets.
- **The only per-market differences are liquidity/price *thresholds*** used by
  the **category gates** (which then feed a ±6 bullish/bearish term into the
  score) and by the **`/screen` liquidity filter** — never the score math
  itself. These are FX-scaling of the legacy IDR figures.
- Empirically, for BBCA/0700/005930 all six scoring inputs are populated (no
  None) and the same components apply.

## 1. Which indicators contribute to the SCORE

Source: `engine.py:_signal_and_score` (lines ~471–504). Base score = **50.0**.

| Contributor (input keys) | Effect on score |
| --- | --- |
| **EMA20 vs EMA50** (`ema20`,`ema50`) | `+12` if EMA20>EMA50 else `-12` |
| **Close vs SMA200** (`close`,`sma200`) | `+10` if Close>SMA200 else `-10` |
| **MACD histogram sign** (`macd_hist`) | `+8` if hist>0 else `-8` |
| **RSI extremes** (`rsi`) | `+6` if RSI<30; `-6` if RSI>70; else `0` |
| **bullish category** (`cats`) | `+6` if present |
| **bearish category** (`cats`) | `-6` if present |

Final score is clamped to `[0,100]` and rounded to 1 dp. Signal: `>=66 BUY`,
`>=40 HOLD`, else `SELL`.

**Indicators that do NOT directly enter the score:** `volume_ratio`,
`value_traded`, `ATR`/`atr_pct`, `CMF`, `VWAP`, `ADX`, `OBV`, `A/D`, SMA20/SMA50.
These feed the **category rules** (`categorize`), and categories influence the
score only through the **±6 bullish/bearish** term. So they contribute
*indirectly and identically* for every market.

> **"Relative Strength":** there is **no** standalone relative-strength
> indicator in the engine. The only `rs` in the code is the internal ratio
> inside the RSI formula (`indicators.py:32`). An analysis *highlight* once read
> "Relative strength vs <market>" as descriptive text, but no RS metric is
> computed or scored. Identical (absent) across all markets.

## 2. Score weight for each indicator

Identical for all four markets (the function has no market branch):

```
score = 50
       ± 12   EMA20 vs EMA50
       ± 10   Close vs SMA200
       ±  8   MACD histogram sign
       +  6 / -6 / 0   RSI < 30 / RSI > 70 / otherwise
       +  6   bullish category
       -  6   bearish category   -> clamp [0,100]
```

Weights are constants in code; **no per-market weighting exists.**

## 3. Market-specific bypasses

There are **no bypasses in the scoring or indicator pipeline.** The only
market-aware code is threshold scaling, used in `categorize` and `/screen`
filtering — not in `_signal_and_score` or `compute_all`:

| Helper | IDX (default) | HKEX | KOSPI | KOSDAQ | Used by |
| --- | --- | --- | --- | --- | --- |
| `_value_floor(2B)` | 2,000,000,000 | 1,000,000 (÷2000) | 166,666,667 (÷12) | 166,666,667 (÷12) | category liquidity gates |
| `_cheap_price` | 300 | 5.0 | 5000 | 5000 | turnaround/silent-accum price ceiling |
| `default_min_value_traded` | 2,000,000,000 | 1,000,000 | 166,666,667 | 166,666,667 | `/screen` liquidity filter + ranking floor |

These FX-scale the legacy IDR thresholds so HKD/KRW markets aren't held to
IDR-sized turnover. They change *which categories fire* and *which rows pass the
screen liquidity filter*, but the **per-stock score weights are unchanged.**

Note: `Market.KOSPI` and `Market.KOSDAQ` use **identical** floors/ceilings (both
Korea, ÷12 / 5000), so KOSPI and KOSDAQ are mutually identical as well.

## 4. None / NaN fallbacks

- `compute_all` uses `last()`/`prev()` helpers that `dropna()` then take
  `iloc[-1]`/`iloc[-2]`, returning **`None`** when the (NaN-dropped) series is
  empty or too short. This is the single, universal fallback for **every**
  indicator and **every** market.
- `_signal_and_score` guards each term with `is not None`: a missing
  `ema20/ema50`, `close/sma200`, `macd_hist`, or `rsi` simply **omits that term**
  (no contribution) rather than crashing. Same behavior on all markets.
- `categorize` uses a `has(...)` guard (all inputs non-None) before each rule, so
  a missing indicator just means that category doesn't fire.
- `value_traded` falls back to `0.0` in screen matches when absent; `atr_pct`
  divides by close only when close not in `(None, 0)`.

No market has a different None/NaN policy.

## 5. Indicators skipped because data unavailable

- Skipping is **data-driven, not market-driven**: warm-up periods (e.g. SMA200
  needs ≥200 bars) or insufficient history yield `None` for that indicator via
  the same `last()` path, and the corresponding score term is omitted. A newly
  listed symbol on *any* market would skip SMA200 the same way.
- If the latest **close** itself is `None`, `analyze`/`_screen_one` treat it as
  "insufficient data" and fall back (mock for `/screen` per-symbol; mock
  analyze) — identical across markets.

## Validation — scoring inputs for BBCA / 0700 / 005930

Empirically pulled (live, 1y daily):

| input | BBCA (IDX) | 0700 (HKEX) | 005930 (KOSPI) |
| --- | --- | --- | --- |
| rsi | 22.71 | 47.06 | 63.27 |
| close | 5,075 | 453.2 | 329,000 |
| ema20 | 5,835.17 | 455.95 | 300,592.39 |
| ema50 | 6,204.84 | 477.79 | 258,013.35 |
| sma200 | 7,480.75 | 572.08 | 150,195.5 |
| macd_hist | -66.37 | 3.835 | 3,141.57 |
| **None among scoring inputs** | **[]** | **[]** | **[]** |
| score → signal | 20.0 → SELL | 30.0 → SELL | 86.0 → BUY |

Score decomposition (same formula each), reconciled exactly to the live scores:
- **BBCA** = 50 −12(EMA20<EMA50) −10(Close<SMA200) −8(hist<0) +6(RSI 22.7<30) −6(bearish) = **20** ✅
- **0700** = 50 −12(EMA20<EMA50) −10(Close<SMA200) +8(hist>0) +0(RSI 47) −6(bearish) = **30** ✅
- **005930** = 50 +12(EMA20>EMA50) +10(Close>SMA200) +8(hist>0) +0(RSI 63) +6(bullish) = **86** ✅

All three reconcile to the live scores using one shared formula → **identical
scoring pipeline and weights confirmed.**

Other audited indicators (all computed, all non-None for these three):
`volume_ratio`, `value_traded`, `atr`/`atr_pct`, `macd`/`macd_signal`, `cmf`,
`vwap`, `adx`, `obv`, `ad` — present for IDX, HKEX, and KOSPI alike.

## Conclusion

**Expected outcome met:** the scoring pipeline and weights are **identical across
IDX, HKEX, KOSPI, and KOSDAQ.** The only market-specific code is FX-scaled
liquidity/price *thresholds* in the category gates and the `/screen` liquidity
filter — these are intentional (so non-IDR markets aren't held to IDR turnover)
and do **not** alter the per-stock score weights, the indicator computation, or
the None/NaN handling. "Relative Strength" is not a scored indicator on any
market. No code changes recommended for parity; the design is already parity-safe.
