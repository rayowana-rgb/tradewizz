# TradeWiz

A clean stock screening & analysis mobile app. Android-first (Flutter).

## Features (v0 scaffold)

- **Dashboard** — market summary header, summary cards, and top movers.
- **Watchlist** — per-market watchlist with swipe-to-remove.
- **Market selector** — switch between IDX, HKEX, KOSPI, KOSDAQ.
- **AI Analysis** — placeholder page with planned features.

> Data is currently sample/placeholder. A real data source still needs wiring in.

## Structure

```
lib/
  main.dart              # App + bottom-nav shell
  theme.dart             # Clean Material 3 theme
  models/
    market.dart          # Market enum (IDX, HKEX, KOSPI, KOSDAQ)
    stock.dart           # Stock model + sample data
  pages/
    dashboard_page.dart
    watchlist_page.dart
    ai_analysis_page.dart
  widgets/
    market_selector.dart
    stock_tile.dart
```

## Run

```bash
cd tradewiz
flutter pub get
flutter run        # connect an Android device/emulator
```

## Next steps

- Wire a real market data API.
- Persist watchlist (e.g. shared_preferences / local DB).
- Build out the AI Analysis features.
