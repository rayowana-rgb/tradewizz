# TradeWizz — Complete UI Redesign Specification
**"The Wizard Terminal" Design Language**
_Senior Product Design spec · Apple Stocks × Arc Browser × Linear · v1.0 · 2026-06-11_

---

## 0. Design Thesis

The TradeWizz icon is a **glossy white wizard emblem** (hat + all-seeing eye + ascending chart nodes) floating on a **muted purple squircle** with soft upper-left lighting. We translate that into a **dark, premium "quant wizard" interface**: deep indigo-violet surfaces, glassy floating cards, an electric blue accent for intelligence/signal, and a clean rounded-geometric type voice.

**Three rules that make every screen feel like the icon:**
1. **Violet depth, blue intelligence.** Backgrounds are violet-indigo; the _only_ saturated color is the blue accent — reserved for AI, actions, and signal. Gains/losses are the second semantic color layer.
2. **Everything floats.** Cards are glass panels lifted off the background with soft ambient shadow + a 1px top-light hairline border (the icon's "embossed" feel, not Material elevation).
3. **Calm, large, confident.** Generous spacing, large headers, slow/smooth motion. Never busy, never neon, never Material.

> **Compliance guardrail (must persist through redesign):** TradeWizz is an _educational research platform_. No "Buy/Sell" CTAs implying execution; AI outputs are framed as **research / scenarios / confidence**, never advice. Keep the "Not a broker · Not financial advice" disclaimer footer on Dashboard, AI Analysis, and Stock Detail.

---

## 1. Color System

### 1.1 Core palette (from the brief, extended into a usable scale)

| Token | Hex | Use |
|---|---|---|
| `bg.base` | `#1B1633` | App scaffold background (darkest) |
| `bg.raised` | `#221B3D` | Sheets, nav bar, scrolled app bar |
| `bg.elevated` | `#2B2350` | Secondary surfaces, hover/pressed bg |
| `surface.card` | `#2F2858` | Floating card fill (base) |
| `surface.cardGlass` | `rgba(47,40,88,0.55)` | Glass card over gradient/hero |
| `accent.primary` | `#4F7CFF` | Primary actions, AI, links, active states |
| `accent.bright` | `#6E8BFF` | Gradient top stop, glow, focus ring |
| `text.primary` | `#FFFFFF` | Titles, primary numbers |
| `text.secondary` | `#D6D8E7` | Body, labels |
| `text.tertiary` | `#AEB3CC` | Captions, metadata, disabled |

### 1.2 Derived tokens (do not improvise — use these)

| Token | Value | Use |
|---|---|---|
| `accent.gradient` | `135° linear(#6E8BFF → #4F7CFF)` | Primary buttons, AI emblem, score rings |
| `bg.heroGradient` | `160° linear(#2B2350 → #1B1633)` | Hero/dashboard top fade |
| `glow.accent` | `0 8px 28px rgba(79,124,255,0.35)` | Primary button + AI card glow |
| `hairline.top` | `1px rgba(255,255,255,0.10)` | Top-light card border (the "emboss") |
| `hairline.edge` | `1px rgba(255,255,255,0.06)` | Full card border / dividers |
| `shadow.ambient` | `0 12px 32px rgba(0,0,0,0.35)` | Floating card drop shadow |
| `shadow.ambientSm` | `0 6px 18px rgba(0,0,0,0.28)` | Chips, small cards |
| `scrim.sheet` | `rgba(10,8,22,0.55)` | Modal/bottom-sheet backdrop |

### 1.3 Semantic colors

| Token | Hex | Use |
|---|---|---|
| `up` | `#3ED598` | Positive change, bullish, confidence-high |
| `up.soft` | `rgba(62,213,152,0.14)` | Gain chip background |
| `down` | `#FF6B81` | Negative change, bearish (softened red — not Material `#E53935`) |
| `down.soft` | `rgba(255,107,129,0.14)` | Loss chip background |
| `warn` | `#FFC56F` | Risk-medium, caution |
| `neutral` | `#AEB3CC` | Flat / no signal |
| `info` | `#6E8BFF` | AI / informational |

> **Confidence color ramp** (AI scores 0–100): `0–39 → down`, `40–69 → warn`, `70–100 → up`. The ring track is always `rgba(255,255,255,0.08)`.

### 1.4 Light mode
This design is **dark-first by identity**. Ship dark only for v1 (matches Apple Stocks dark, Linear, Arc dark). If light mode is later required, mirror with: `bg.base #F4F3FA`, `surface.card #FFFFFF`, accent unchanged, text inverted. Do **not** auto-follow system for v1 — lock dark.

---

## 2. Typography Scale

Icon wordmark is a **bold rounded geometric sans**. Match it with **SF Pro Rounded** on iOS / **Manrope** (bundled) cross-platform. Numbers use **tabular figures** everywhere (`fontFeatures: [FontFeature.tabularFigures()]`).

| Style | Size / Line | Weight | Tracking | Use |
|---|---|---|---|---|
| `display` | 34 / 40 | 800 | -0.5 | Greeting "Good morning" |
| `title1` | 28 / 34 | 700 | -0.4 | Screen titles, hero price |
| `title2` | 22 / 28 | 700 | -0.3 | Section headers, card titles |
| `title3` | 18 / 24 | 600 | -0.2 | Sub-headers, list item title |
| `body` | 16 / 24 | 500 | 0 | Default body, chat text |
| `bodySm` | 14 / 20 | 500 | 0 | Secondary body |
| `label` | 13 / 16 | 600 | 0.2 | Chips, buttons, tab labels |
| `caption` | 12 / 16 | 500 | 0.2 | Metadata, timestamps |
| `overline` | 11 / 14 | 700 | 1.2 (UPPER) | Section eyebrows ("MARKET SENTIMENT") |
| `mono.num` | 17 / 22 | 600 tabular | 0 | Prices, % change, scores |

**Font weights mapping:** display/heroes = 700–800; everything else ≤ 600 to avoid "shouting." Never use weight 900.

---

## 3. Spacing, Radius, Layout

### 3.1 Spacing scale (4-pt base, but lean large)
`space = {xs:4, sm:8, md:12, lg:16, xl:20, 2xl:28, 3xl:40, 4xl:56}`

- **Screen gutter:** `xl (20)` horizontal, content max-width 720 on tablets (center).
- **Section gap:** `2xl (28)` between major cards/sections.
- **Inside card padding:** `xl (20)` (compact cards `lg 16`).
- **List item vertical:** `md–lg (12–16)`.

### 3.2 Corner radius (brief: 20–28)
| Token | Radius | Use |
|---|---|---|
| `r.card` | 24 | Floating cards (default) |
| `r.cardLg` | 28 | Hero / feature cards, sheets (top corners) |
| `r.chip` | 999 | Chips, pills, segmented control |
| `r.button` | 16 | Buttons, inputs |
| `r.sm` | 12 | Sparkline tiles, avatars, small thumbs |

### 3.3 Grid
- Single column phone; **2-col** trending/watchlist on ≥600dp.
- Carousels: card width `78%` of viewport, `peek` next card by `space.xl`, snap physics.

---

## 4. Component Library (Flutter)

All custom widgets live in `lib/widgets/ds/` (design-system). Build these **first**; screens compose them.

### 4.1 Foundation widgets

| Widget | File | Spec |
|---|---|---|
| `GlassCard` | `ds/glass_card.dart` | The atom. `BackdropFilter(blur 18)` + `surface.cardGlass` fill + `hairline.top` gradient border + `shadow.ambient`, radius `r.card`. Param: `padding`, `radius`, `onTap`, `glow`. |
| `FloatingCard` | `ds/glass_card.dart` | Opaque variant (`surface.card`) for scroll lists where blur is costly — same border/shadow, no `BackdropFilter`. **Use this in long lists for perf; reserve `GlassCard` for heroes/overlays.** |
| `GradientButton` | `ds/buttons.dart` | `accent.gradient` fill, `r.button`, `glow.accent`, label `label` style, 52px height, press-scale 0.97. |
| `GhostButton` | `ds/buttons.dart` | Transparent + `hairline.edge`, text `accent.primary`. |
| `Chip` / `FilterChip` | `ds/chips.dart` | Pill `r.chip`, unselected `bg.elevated`+hairline, selected `accent.primary` fill / white text. |
| `DeltaChip` | `ds/delta_chip.dart` | Gain/loss chip: `up.soft`/`down.soft` bg, arrow glyph + `+1.24%`, mono tabular. |
| `Sparkline` | `ds/sparkline.dart` | CustomPaint mini line, gradient stroke = up/down color, soft area fill `0.12` alpha, no axes. |
| `ScoreRing` | `ds/score_ring.dart` | Circular confidence 0–100, sweep gradient on ramp color, track `rgba(255,255,255,0.08)`, center number `mono.num`. |
| `SectionHeader` | `ds/section_header.dart` | `overline` eyebrow + `title2` + optional trailing action. |
| `Eyebrow` | `ds/section_header.dart` | Standalone overline label. |
| `AiOrb` | `ds/ai_orb.dart` | The wizard emblem — small gradient orb w/ subtle inner glow + the hat/eye glyph; used as AI avatar + empty-state mascot. |
| `EmptyState` | `ds/empty_state.dart` | `AiOrb` + title + body + optional CTA (matures the existing journal/broker empty states). |

### 4.2 Navigation
- **Bottom bar:** custom `GlassNavBar` (`ds/glass_nav_bar.dart`) — floating, detached from bottom by `space.lg`, `r.cardLg`, blur, 5 tabs. Active tab: filled `accent.gradient` icon chip + label; inactive: `text.tertiary` icon only. **No Material `BottomNavigationBar`.** Tabs: **Home · Watchlist · Screener · AI · Settings** (AI is center, slightly raised, accent-glow).
- **App bar:** transparent → on scroll fades to `bg.raised` with bottom `hairline.edge`. Large-title collapse like Apple (use `SliverAppBar.large` styled, not stock Material look).

### 4.3 Iconography rules
- **Set:** Phosphor Icons (`phosphor_flutter`) **Regular** weight default, **Fill** only for active nav/selected states. Consistent 1.5px optical weight → matches the icon's clean strokes (avoid Material `Icons.*`).
- **Size:** 20 inline, 24 nav/actions, 28 hero.
- **Color:** `text.secondary` default; `accent.primary` for interactive/AI; semantic for signal.
- **Custom glyphs:** wizard-hat + eye reserved exclusively for the AI brand mark (`AiOrb`), never decorative.

---

## 5. Motion & Animation

| Interaction | Spec |
|---|---|
| Page transition | Shared-axis Z / fade-through, **320ms `easeOutCubic`** (use `PageTransitionsTheme` w/ custom builder; iOS keeps Cupertino swipe-back but with our fade). |
| Card tap (hover/press elevation) | Scale `1.0→0.98`, shadow `ambient→ambientSm`, **140ms easeOut**; release springs back (`Curves.easeOutBack`, 220ms). |
| Hero chart → detail | `Hero` tag `stock-{symbol}`; sparkline morphs into full chart, **420ms easeInOutCubic**, background cross-fades. |
| List/card entrance | Staggered fade+rise (`y:+12→0`, opacity 0→1), 60ms stagger, 300ms each. |
| Number changes (price/score) | `AnimatedFlipCounter`-style roll, 400ms; color flash up/down 600ms then settle. |
| Sheet present | Slide-up + scrim fade, 360ms `easeOutCubic`, rounded top `r.cardLg`, grabber handle. |
| Loading | **Skeleton shimmer** on glass cards (never spinners on content). Subtle `accent` shimmer sweep. |
| Reduce-motion | Respect `MediaQuery.disableAnimations` → swap to instant/opacity-only. |

**Global feel:** slow-in, gentle, never bouncy-cartoonish except the press-release micro-spring. Default curve = `easeOutCubic`. Default duration = `280ms`.

---

## 6. Screen Specifications

### 6.1 Dashboard (`pages/dashboard_page.dart` / `home_page.dart`)
**Layout (vertical scroll, `bg.heroGradient` top 280px fading to `bg.base`):**

1. **Greeting header** — `display` "Good morning, {name}" + `caption` date/market-status pill (`● Markets open` w/ `up` dot). Trailing: `AiOrb` avatar → opens AI. Large, no app-bar title (title appears only on scroll).
2. **Portfolio summary card** (`GlassCard`, `r.cardLg`, glow subtle) — eyebrow "SIMULATED PORTFOLIO", big `title1` total value (mono), `DeltaChip` today's change, tiny full-width `Sparkline` of equity curve, 3 mini stats row (Cash · Buying Power · Realized P/L). Tag "Simulation" pill top-right (compliance).
3. **Market sentiment card** — eyebrow "MARKET SENTIMENT", a horizontal **sentiment meter** (Fear↔Greed gradient bar with marker) + label ("Cautiously Bullish"), 3 index chips (S&P/NDX/DJI) w/ `DeltaChip`.
4. **AI insights card** (accent-glow, the star) — `AiOrb` + "Wizz sees…" → 1–2 reasoning bullets w/ confidence `ScoreRing` mini, CTA `GhostButton` "Open analysis". Clearly labeled "AI research · not advice".
5. **Trending stocks carousel** — `SectionHeader` "Trending" + horizontal snap carousel of `StockMiniCard` (logo mono badge, symbol, price, `Sparkline`, `DeltaChip`).
6. Footer disclaimer (`caption`, `text.tertiary`).

**Hierarchy:** `DashboardPage → CustomScrollView[ GreetingHeader, PortfolioSummaryCard, MarketSentimentCard, AiInsightCard, TrendingCarousel, DisclaimerFooter ]`.

### 6.2 Watchlist (`pages/watchlist_page.dart`)
- **Header:** large title "Watchlist" + segmented `Chip` filter (All · Gainers · Losers · Recent).
- **Floating watchlist cards** — each row is a `FloatingCard` (`r.card`, `space.md` gap, full-width) containing: left = mono logo badge + symbol (`title3`) + company (`caption tertiary`); center = `Sparkline` (intraday, up/down colored); right = price (`mono.num`) stacked over `DeltaChip`. Swipe-left → glass action (Remove / Set alert). Tap → Stock Detail (Hero).
- **Empty state:** `EmptyState` (`AiOrb`, "Your watchlist is empty", "Add stocks from Screener", CTA).
- **Reorder:** long-press lifts card (scale 1.03 + bigger shadow), drag to reorder.

### 6.3 Screener (`pages/screener_page.dart`)
- **Sticky top:** search field (`r.button`, glass) + **category chips** row (horizontal scroll: Momentum · Value · Dividend · AI Picks · Volume · Breakout) + trailing **"Filters" pill** (count badge) → opens **Advanced filter sheet**.
- **Advanced filter sheet** (`ds/filter_sheet.dart`, bottom sheet, `r.cardLg`, grabber): grouped sections (Market, Price range dual-slider, Market-cap, Sector chips, Score range, Liquidity/participation), each in a `GlassCard` group; sticky footer `GradientButton` "Show N results" + "Reset". Persists selection (existing Explore filter store).
- **Results:** list of **stock cards w/ confidence score** — `FloatingCard`: row1 logo+symbol+name + `ScoreRing` (confidence, right); row2 price + `DeltaChip` + `Sparkline`; row3 micro tag chips (sector, signal). Sort control (Score ▾ / Price / % / Volume).
- **Loading:** 6 skeleton cards shimmer.

### 6.4 AI Analysis (`pages/ai_analysis_page.dart`)
**ChatGPT-style conversation, but card-rich:**
- **Layout:** scroll of message bubbles; user bubbles right (`accent.gradient`, white), Wizz responses left with `AiOrb` avatar and **no bubble** — instead Wizz answers _as stacked cards_:
  - **AI reasoning card** — `GlassCard`, eyebrow "REASONING", stepwise bullets, expandable "Show work".
  - **Prediction card** — scenario ranges (Base / Bull / Bear) as 3 mini columns w/ probability `%` and target, `Sparkline` fan. Eyebrow "SCENARIOS (not advice)".
  - **Risk assessment card** — `ScoreRing` risk level + factors list w/ `warn`/`down`/`up` dots (Volatility, Liquidity, Drawdown).
- **Composer (pinned bottom, glass):** rounded input + send `GradientButton` (mic optional), suggested-prompt chips above it ("Analyze AAPL", "Compare NVDA vs AMD", "Explain my portfolio risk").
- **Streaming:** token-by-token text reveal + a thinking shimmer on the pending card. Always-visible "AI can be wrong · educational only" caption.

### 6.5 Stock Detail (`pages/stock_detail` — new, reachable from Watchlist/Screener/Trending)
1. **Hero chart** — full-bleed top (`bg.heroGradient`), `Hero` from sparkline; price `title1` mono + `DeltaChip`; **timeframe segmented control** (1D 1W 1M 3M 1Y ALL); interactive line chart with drag-scrub crosshair + value bubble; area gradient up/down.
2. **AI recommendation banner** — accent-glow `GlassCard` directly under hero: `AiOrb` + a **stance** ("Wizz: Constructive · 72 confidence" via `ScoreRing`) + one-line rationale + "View full analysis" → AI page. **Framed as research, labeled not-advice.**
3. **Fundamentals section** — `SectionHeader` + 2-col grid of stat tiles (`r.sm`): Mkt Cap, P/E, EPS, Div Yield, Revenue, 52w H/L. Tabular numbers.
4. **Technical indicators section** — RSI gauge, MACD mini, MA cross status, support/resistance chips; each a compact `GlassCard` with plain-language one-liner.
5. **News section** — list of `FloatingCard` news rows (source badge, headline `title3`, time `caption`, sentiment dot). Tap → in-app reader / external.
6. Sticky bottom bar: **"Add to Watchlist"** (`GradientButton`) + "Simulate position" `GhostButton` (opens existing order ticket, labeled Simulation). **No real Buy/Sell.**

### 6.6 Settings (`pages/account_page.dart`)
Keep the **4-section IA from Phase 11C** (Portfolio · Insights · Connections · Account) but reskinned:
- Profile header card (`GlassCard`): avatar/`AiOrb`, name, email, plan pill (Free/Pro w/ accent).
- Grouped **`SettingsGroup`** cards (`ds/settings_group.dart`): each group = `FloatingCard` with `overline` header + rows (`SettingsRow`: leading Phosphor icon in tinted square, title, trailing chevron/`Switch`/value). Replaces Material `ListTile` look.
- Sections: **Portfolio** (Simulated portfolio, Trade Journal), **Insights** (AI preferences, Health), **Connections** (Connected Brokers — labeled read-only/educational), **Account** (Plan/Upgrade, Notifications, Appearance(locked dark), Privacy/Terms/Support links → the GitHub Pages URLs, Sign out).
- Footer: version + "Not a broker · Not financial advice" + legal links.

---

## 7. Component Hierarchy (tree)

```
TradeWizApp
└─ AppShell (Scaffold, bg.base)
   ├─ GlassNavBar (Home · Watchlist · Screener · AI · Settings)
   └─ IndexedStack
      ├─ DashboardPage
      │  └─ CustomScrollView
      │     ├─ GreetingHeader
      │     ├─ PortfolioSummaryCard  → GlassCard + Sparkline + DeltaChip
      │     ├─ MarketSentimentCard   → SentimentMeter + DeltaChip×3
      │     ├─ AiInsightCard         → AiOrb + ScoreRing + GhostButton
      │     ├─ TrendingCarousel      → StockMiniCard[] (Sparkline, DeltaChip)
      │     └─ DisclaimerFooter
      ├─ WatchlistPage → ListView(FloatingCard[ logo, Sparkline, price, DeltaChip ])
      ├─ ScreenerPage
      │  ├─ SearchField + CategoryChips + FilterPill→FilterSheet
      │  └─ ListView(StockScoreCard[ ScoreRing, Sparkline, tags ])
      ├─ AiAnalysisPage → ChatList[ UserBubble | (AiOrb + ReasoningCard + PredictionCard + RiskCard) ] + Composer
      └─ SettingsPage → ProfileCard + SettingsGroup[](SettingsRow[])
   StockDetailPage (pushed)
      └─ Sliver[ HeroChart, AiRecBanner, Fundamentals, Technicals, News, StickyActions ]

ds/ (foundation): GlassCard, FloatingCard, GradientButton, GhostButton,
   Chip, DeltaChip, Sparkline, ScoreRing, SectionHeader, Eyebrow,
   AiOrb, EmptyState, GlassNavBar, FilterSheet, SettingsGroup
```

---

## 8. Implementation Plan (incremental, test-safe)

> The existing test suite (219 tests) depends on widget **keys** and page structure. Reskin is **view-layer only** — preserve all `Key`s, page classes, route names, and store/repository wiring. Wrap visuals; don't rename.

1. **Tokens first** — replace `theme.dart` with the dark token system below (Step in §9). Add `Manrope`/SF Rounded to `pubspec.yaml` fonts; add `phosphor_flutter`.
2. **Build `lib/widgets/ds/`** foundation widgets + golden tests for each (visual regression).
3. **Reskin per screen** in this order: Dashboard → Watchlist → Screener → Stock Detail (new) → AI Analysis → Settings. After each, run `flutter test` + `flutter analyze` (keep green).
4. **Motion pass** — page transitions theme, Hero tags, card press, skeletons.
5. **QA** — dark contrast (WCAG AA on text over surfaces), reduce-motion, 2-col tablet, perf (use `FloatingCard` not blur in long lists).

---

## 9. Drop-in Theme Tokens (Flutter)

A ready `theme.dart` replacement is provided at `lib/theme_tradewizz.dart` (see companion file). It exposes `TWColors`, `TWType`, `TWSpace`, `TWRadius`, `TWShadow`, and `buildTradeWizzTheme()` (Material3 dark, transparent app bar, our card/radius defaults) so screens can adopt incrementally while keeping `buildTradeWizTheme()` working during migration.

---

## 10. "Same family as the icon" checklist (per screen)
- [ ] Violet-indigo background, blue is the only saturated accent
- [ ] Cards float (glass/opaque + top-light hairline + soft ambient shadow), radius 24–28
- [ ] Rounded geometric type, tabular numbers, large headers, generous spacing
- [ ] Phosphor icons, 1.5px feel; wizard glyph only for AI brand
- [ ] Smooth easeOutCubic motion; Hero chart; press micro-spring
- [ ] No Material ripple/elevation look; no neon
- [ ] Educational framing intact; "not a broker / not advice" present where required
```
