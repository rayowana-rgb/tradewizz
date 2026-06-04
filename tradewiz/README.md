# TradeWiz

A clean stock screening & analysis mobile app. **iOS-first** (Android supported),
built with Flutter. TradeWiz is the mobile evolution of an existing Telegram
stock-screening bot — the backend API mirrors the bot's capabilities.

## Features (current scaffold)

- **Dashboard** — market summary header, summary cards, and top movers.
- **Screener** — runs `/screen/{market}`, lists tagged matches with category
  badges (bullish, bearish, scalping, accumulation, pullback, silent
  accumulation, turnaround multibagger, frequently traded, short candidate,
  ARA hunter). Filter by market and category; pull-to-refresh; loading/error/
  empty states. Shows “Showing X of Y” with a **Load more** button (limit grows
  by 50 up to 200) when the backend reports more matches than returned.
- **Watchlist** — per-market watchlist with swipe-to-remove; tap a row to open
  its analysis. **Persists across launches** via `shared_preferences`.
- **Market selector** — switch between IDX, HKEX, KOSPI, KOSDAQ.
- **AI Analysis** — enter a symbol + market, get a placeholder analysis result
  and weekly forecast (wired through the repository/API layer). **Save to
  Watchlist** from the result. Tapping a screener match opens this page with the
  symbol/market prefilled and auto-runs `/analyze/{symbol}` (with back nav).

> Data is placeholder. The API client returns mocked JSON shaped like the real
> backend so the UI is fully buildable/testable before the bot API is connected.

## Architecture

UI → **Repository** → **ApiClient** (real HTTP via `package:http`) → backend.

The API client performs real `GET`s against `AppConfig.baseUrl` with a timeout
and friendly error mapping. If the backend is unreachable (timeout / socket /
client error) and `mockFallback` is on, it falls back to mocked JSON so the app
stays usable offline. Non-2xx responses surface a friendly `ApiException`
(no silent fallback). Every result is tagged with a **`DataSource`**
(`live` / `fallback` / `offline` / `error`) carried from the client through the
repository to the UI, surfaced as a **connection pill/banner** on the Dashboard,
Screener, and Analysis result. The banner offers a **Retry** action to attempt
reconnecting to the live backend.

Configure the base URL at build time:

```bash
flutter run --dart-define=TRADEWIZ_API_BASE_URL=https://staging.tradewiz.app/v1
```

```
lib/
  main.dart                    # App + bottom-nav shell
  theme.dart                   # Material 3 theme
  models/
    market.dart                # Market enum (IDX, HKEX, KOSPI, KOSDAQ)
    stock.dart                 # Stock + sample data
    analysis_result.dart       # AnalysisResult, WeeklyPrediction
    screener_result.dart       # ScreenerResult, ScreenerMatch
    screener_category.dart     # ScreenerCategory enum (badges)
    watchlist_item.dart        # WatchlistItem (persistable)
  config/
    app_config.dart            # baseUrl/timeout via --dart-define
  services/
    api_client.dart            # Real HTTP (package:http) + mock fallback
    repository_scope.dart      # InheritedWidget exposing StockRepository
    data_source.dart           # DataSource enum + Sourced<T> wrapper
    watchlist_store.dart       # Shared ChangeNotifier state + persistence
    watchlist_scope.dart       # InheritedNotifier exposing the store
  repositories/
    stock_repository.dart      # UI-facing data access
  pages/
    dashboard_page.dart
    screener_page.dart         # Market/category-filtered screener
    watchlist_page.dart
    ai_analysis_page.dart      # Form-driven analysis
  widgets/
    market_selector.dart
    category_badge.dart
    connection_pill.dart       # Live/Mock/Offline/Error pill + banner (Retry)
```

### Planned API endpoints

| Endpoint                   | Method | Returns            |
| -------------------------- | ------ | ------------------ |
| `/analyze/{symbol}`        | GET    | `AnalysisResult`   |
| `/screen/{market}`         | GET    | `ScreenerResult`   |
| `/predict_weekly/{symbol}` | GET    | `WeeklyPrediction` |

To go live: replace `ApiClient._mockGet` with a real HTTP implementation
(`http`/`dio`) pointing at `baseUrl`. Models already parse the target JSON shape.

## Run

```bash
cd tradewiz
flutter pub get
flutter run        # iOS simulator or device (Android also supported)
```

## End-to-end smoke test

Verify the app receives **live** backend data (not mock fallback) against a real
server. One command (starts the backend, runs the live test, tears down):

```bash
../scripts/e2e_smoke.sh          # from tradewiz/, or run from repo root
```

Or manually:

```bash
# terminal 1: backend
cd ../backend && source .venv/bin/activate && uvicorn app.main:app --port 8000

# terminal 2: live test (excluded from the default run)
flutter test --tags live \
  --dart-define=TRADEWIZ_API_BASE_URL=http://localhost:8000/v1 \
  --dart-define=RUN_LIVE=true
```

The default `flutter test` stays hermetic — the live suite self-skips unless
`RUN_LIVE=true` is set.

## Next steps

- Connect the real (migrated bot) backend.
- iOS polish: Cupertino touches where it improves UX.
