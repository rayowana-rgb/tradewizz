# Universe Files: Excel (legacy) vs current CSV — Analysis

> **UPDATE 2026-06-04:** Migration executed. The backend now uses the Excel
> universes as the **primary source** with per-market normalization on load
> (HKEX filtered to equity codes 1..9999; `kospi.xlsx` routed by suffix into
> KOSPI `.KS` / KOSDAQ `.KQ`; suffixes stripped to bare symbols). Loaded sizes:
> IDX 956, HKEX 3822, KOSPI 948, KOSDAQ 1822 (KOSPI/KOSDAQ disjoint). CSV is now
> the fallback. See `app/universe.py` and the backend README. Original analysis
> below.


**Date:** 2026-06-04 22:14 (GMT+8)
**Scope:** Analysis only. No code or data was changed. Recommendation on whether
the `*.xlsx` universes should replace the current `*.csv` universes.

## Files present

`backend/data/universe/`:

| Market | CSV | XLSX | XLSX size | XLSX rows |
|---|---|---|---|---|
| IDX    | `idx.csv` (10) | `idx.xlsx` | 69 KB | 956 |
| HKEX   | `hkex.csv` (10) | `hkex.xlsx` | 938 KB | 17,671 |
| KOSPI  | `kospi.csv` (10) | `kospi.xlsx` | 150 KB | 2,770 |
| KOSDAQ | `kosdaq.csv` (10) | **— none —** | — | — |

All three xlsx share the same template columns (clearly exported from an
IDX/IDX-bot source): `No, Symbol, Name, Tanggal Pencatatan, Saham,
Papan Pencatatan`. The loader (`app/universe.py`) only needs `Symbol` (+ optional
`Name`), which are present, so the files parse without error.

## How the loader uses these today

**Critical:** `UniverseRepository._resolve_path` checks extensions in order
`(.csv, .xlsx, .xls)` and returns the **first match**. Since every market has a
`.csv`, **the `.xlsx` files are currently never read** — they are inert. Today's
universes are still the 10-symbol hand-curated CSVs.

`yf_symbol(symbol, market)` is idempotent: it appends the market suffix only if
absent. So pre-suffixed symbols mostly work — **except** when the suffix doesn't
match the market (see KOSPI below).

## Per-file findings

### IDX (`idx.xlsx`) — clean, genuine upgrade
- 956 rows, bare uppercase symbols (`AALI, ABBA, …`), all unique.
- Convention matches the CSV (bare → `yf_symbol` adds `.JK`).
- **Superset of the current CSV**: all 10 CSV symbols are present, plus 946 more.
- `Name` column populated. Extra columns are harmless (loader ignores them).
- **Verdict: high quality. A real expansion (10 → 956).**

### HKEX (`hkex.xlsx`) — mostly NON-equities (noisy)
- 17,671 rows, symbols pre-suffixed `00001.HK` (zero-padded). `yf_symbol`
  leaves them as-is (correct).
- Code-range breakdown:
  - 1–9999 (mostly ordinary equities): **3,822**
  - 10000–29999: 7,482
  - 30000–79999 (**warrants / CBBCs**): **5,964**
  - 80000+ (**DRs / other**): 403
- ~**78% of rows are derivatives/structured products**, not screenable stocks.
- The `Papan Pencatatan` column actually holds **ISIN codes**, not board names —
  the file was repurposed from the IDX template (header is misleading; harmless
  to the loader but signals low curation).
- **Verdict: large but unfiltered. Would flood `/screen/HKEX` with warrants/CBBCs
  and ~17k symbols → very slow cold screens. Not usable as-is.**

### KOSPI (`kospi.xlsx`) — MISLABELED / contaminated
- 2,770 rows. Symbol suffix breakdown: **`.KQ` = 1,822** and **`.KS` = 948**.
- It is actually a **combined Korea (KOSPI + KOSDAQ)** export, not a KOSPI file.
- Loaded as the KOSPI universe, the 1,822 `.KQ` rows hit a **double-suffix bug**:
  `yf_symbol("230980.KQ", KOSPI)` → `230980.KQ.KS` (invalid yfinance ticker) →
  every KOSDAQ row fetch-fails and falls back to per-symbol mock data.
- **Verdict: wrong market mapping. Must be split into KOSPI (`.KS`) and KOSDAQ
  (`.KQ`) before use.**

### KOSDAQ — no xlsx
- There is **no `kosdaq.xlsx`**. The KOSDAQ universe (correctly) belongs to the
  `.KQ` rows that are currently misfiled inside `kospi.xlsx`.

## Compatibility summary

| Concern | IDX | HKEX | KOSPI |
|---|---|---|---|
| Symbol column present | ✅ | ✅ | ✅ |
| Symbol convention OK for `yf_symbol` | ✅ bare | ✅ `.HK` | ⚠️ mixed `.KS`/`.KQ` |
| Real equities only | ✅ | ❌ ~22% | ⚠️ + wrong market |
| Read today (CSV-precedence) | ❌ inert | ❌ inert | ❌ inert |

Other cross-cutting effects if these were activated:
- **Screen latency:** `/screen` fetches every universe symbol (parallelized, 8
  workers, cached). Going 10 → 956/17,671/2,770 makes the **cold** screen far
  slower; HKEX at 17k is impractical. Pagination already caps *output* (limit
  ≤200), but the engine still *fetches/scores the whole universe* before
  truncating — so big universes are a real cost.
- **Liquidity gates:** Phase-2 category rules already gate on `value_traded`,
  which naturally filters illiquid noise — but only *after* fetching each symbol.
- **Loader behavior:** no dedupe issue (all unique), no header issue (Symbol/Name
  resolved), extra columns ignored. Encoding of Korean names is fine (read as
  UTF-8 strings).

## Recommendation

**Do not wholesale-replace the CSVs with these xlsx files as-is.** Mixed verdict:

1. **IDX — adopt (with care).** `idx.xlsx` is a clean, genuine 10→956 upgrade.
   Worth switching to, but note the screen-latency cost; consider keeping a
   curated subset or adding a "top-N by liquidity" pre-filter before screening
   the full list.
2. **HKEX — do NOT adopt as-is.** Must be filtered to ordinary equities
   (drop warrants/CBBCs/DRs — i.e. restrict to the equity code ranges) before it
   is usable. 17k rows of mostly derivatives is wrong for a stock screener.
3. **KOSPI — do NOT adopt as-is.** It is a combined Korea file and is
   **mismapped**; it must be **split** into a true KOSPI (`.KS`) file and a
   KOSDAQ (`.KQ`) file. As-is it breaks KOSDAQ tickers via double-suffixing.
4. **KOSDAQ — source it from the `.KQ` rows currently inside `kospi.xlsx`.**

### Practical path (when code changes are later approved)
- Treat the xlsx as **raw source data**, not drop-in universes.
- Add a one-off **normalization step**: per market, select equity rows, strip/
  fix suffixes to the loader's expected convention, split Korea by suffix,
  filter HKEX to equity code ranges, and emit clean `*.csv` (or `*.xlsx`).
- Decide a **universe-size policy** (e.g. cap at top-N by turnover, or a
  pre-screen liquidity filter) so `/screen` cold latency stays acceptable.
- Because CSV currently wins over xlsx, simply dropping xlsx in place would have
  **no effect**; activation requires either removing the CSVs or changing
  resolution precedence — another reason to normalize into CSVs deliberately.

## Bottom line

The Excel files are **valuable raw material** (especially IDX), but they are
**not clean, market-correct, equities-only universes**. They should be
**normalized and split**, not adopted verbatim. Until then, the current curated
CSVs remain the safer default — and note the xlsx files are inert anyway under
the present CSV-first loader precedence.
