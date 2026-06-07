# Analysis Page UI Parity Audit — IDX / HKEX / KOSPI / KOSDAQ

**Date:** 2026-06-07 10:00 GMT+8
**Scope:** Audit only. No code changed. Investigates whether the iPhone Analysis
UI shows HKEX/KOSPI with less richness than IDX.

## TL;DR

- **No UI parity defect found.** The Analysis page renders highlights and all
  Phase-3 cards **identically for every market** — there is **no
  `if (market == idx)` branch**, no currency assumption in rendering, and no
  widget hidden for non-IDX markets.
- The highlights list is rendered **generically** (`...result.highlights.map(...
  Text(h))`), so it displays exactly whatever the backend returns, in any
  currency, for any market.
- **Verified live:** IDX/HKEX/KOSPI all return **9 highlights** plus the same
  Phase-3 fields (recommendation, buy_reasons, S/R, trailing stop, profit
  probability) — with correct currency symbols (Rp / HK$ / ₩). HKEX and KOSPI
  are **not** less detailed.

## 1–3. Fields displayed per market (IDX / HKEX / KOSPI)

The result card always renders **every** string in `AnalysisResult.highlights`
(generic `.map`), then conditionally renders the Phase-3 cards **based on data
presence, not market**. Live data confirms parity:

| Section | IDX (BBCA) | HKEX (0700) | KOSPI (005930) |
| --- | --- | --- | --- |
| Market Status | ✅ | ✅ | ✅ |
| Last Market Close / Timestamp | ✅ | ✅ | ✅ |
| Current Price | ✅ Rp5,075.00 | ✅ HK$453.20 | ✅ ₩329,000.00 |
| 20-Day Average Price | ✅ | ✅ | ✅ |
| Today's Volume | ✅ | ✅ | ✅ |
| 20-Day Average Volume | ✅ | ✅ | ✅ |
| Value Traded Today | ✅ Rp2.91 Trillion | ✅ HK$14.34 Billion | ✅ ₩11.10 Trillion |
| Volume Ratio | ✅ | ✅ | ✅ |
| ATR | ✅ | ✅ | ✅ |
| **Highlights count** | **9** | **9** | **9** |
| Recommendation card | ✅ | ✅ | ✅ |
| Buy reasons | ✅ (1) | ✅ (1) | ✅ (3) |
| Support / Resistance card | ✅ | ✅ | ✅ |
| Trailing Stop card | ✅ | ✅ | ✅ |
| Profit probability | ✅ 0.2 | ✅ 0.3 | ✅ 0.86 |
| Weekly Prediction card | ✅ | ✅ | ✅ |
| Backtest card | ✅ | ✅ | ✅ |

All three markets are **identical in structure and field count**; only the
*values* and *currency symbol* differ (correctly). KOSDAQ uses the same code path
(no market branch) so it behaves the same.

## 4. Market-specific UI logic (the complete list)

Searched `lib/pages/ai_analysis_page.dart` (the only analysis page; there is no
separate `AnalysisSummary` widget). Findings:

- `lib/pages/ai_analysis_page.dart:80` — `late Market _market = widget.market ??
  Market.idx;` → this is only the **default selection** for the market dropdown
  when none is provided. It does **not** branch rendering.
- `_BuySellButtons._tradable => market.tradableViaMoomoo` → the **only**
  market-conditional widget. It shows Buy/Sell for tradable markets (HKEX) and a
  "not tradable via Moomoo" note otherwise. This concerns **brokerage**, not data
  richness, and is by design.
- **No** `if (market == idx)` highlight/card branch exists.
- **No** parser assumes IDR/Rp: `AnalysisResult.fromJson` maps every highlight
  string verbatim (`analysis_result.dart:66`); the result card renders them as-is.
- **No** widget is hidden for non-IDX markets (the Phase-3 cards are gated on
  `!= null` / non-empty data, identical for all markets).

### Currency note (offline mock only — not a live UI defect)
The **offline mock** in `api_client.dart` (`_mockAnalyze`) hardcodes `Rp` for the
price/value highlight strings regardless of market. This only affects the
**mock-fallback** path (backend unreachable). On live data the backend already
emits the correct currency (Rp/HK$/₩), and the UI renders it verbatim. So even
this is cosmetic and limited to offline mode; it does **not** make HKEX/KOSPI
*less detailed* — the field set and count are still identical.

## 5. Why might HKEX/KOSPI *appear* less detailed?

There is **no rendering reason** — the UI and parser are fully market-agnostic
and the backend returns identical richness (verified). If a user perceives
HKEX/KOSPI as less detailed, the cause is **data availability at fetch time**,
not the UI:

- **Mock fallback:** if a live HKEX/KOSPI analyze request fails (network/Yahoo
  429/timeout) and `mockFallback` is on, the app shows the **offline mock**
  highlights — which use `Rp` and placeholder numbers. The connection pill turns
  orange ("Mock") in that case. This would look "wrong" (Rp on a HK stock) but
  still shows all 9 highlights + all cards. (The earlier `TRADEWIZ_MOCK_FALLBACK`
  dart-define can disable this to surface the real error instead.)
- **Per-field null gating:** if the backend ever returned `support_resistance`
  / `trailing_stop` as null for a thinly-traded HKEX/KOSPI symbol with sparse
  history, that card would be hidden — but this is **data-driven and identical
  across markets** (a thin IDX symbol behaves the same), not a market bias.
- **Stale/insufficient history:** a newly listed HKEX/KOSPI symbol with <200
  bars yields some `None` indicators, which can drop a category/recommendation —
  again data-driven, market-neutral.

## Conclusion

**No UI parity defect.** `AnalysisDetailPage` → `AiAnalysisPage` → `_ResultCard`
+ Phase-3 cards render the same fields for IDX, HKEX, KOSPI, and KOSDAQ, with no
market branch and no Rp-only assumption in the live path. Backend richness is
identical across markets (live-verified: 9 highlights + all cards for
BBCA/0700/005930).

If HKEX/KOSPI ever *look* sparser to a user, it is from **mock fallback** (live
fetch failed → offline placeholder, currency shows Rp, pill shows "Mock") or
**insufficient data** for a specific symbol — both data-availability issues, not
UI logic. No code changes are required for parity.

### Optional follow-ups (not part of this audit)
- Make the **offline mock** currency-aware (use `market.currency`) so the
  fallback doesn't show `Rp` on HK/KR symbols — cosmetic, mock-only.
- Surface the data-source state more prominently on the Analysis card (the
  "Mock" pill already exists) so users know when they're seeing fallback data.
