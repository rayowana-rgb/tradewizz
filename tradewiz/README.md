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
  empty states.
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

UI → **Repository** → **ApiClient** → backend.

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
  services/
    api_client.dart            # HTTP-ready client (stubbed transport)
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
    stock_tile.dart
    category_badge.dart
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

## Next steps

- Connect the real (migrated bot) backend.
- iOS polish: Cupertino touches where it improves UX.
