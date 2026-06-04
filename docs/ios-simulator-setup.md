# iOS Simulator Setup & Visual Pass — TradeWiz

This documents how to run TradeWiz on the iOS Simulator against the local
backend, and the exact fixes for the toolchain gaps found on this machine.

## `flutter doctor` findings (2026-06-04)

- ✅ **Flutter** 3.44.1 (stable), macOS 26.2 arm64
- ❌ **Xcode** — incomplete/not selected. `Xcode.app` (16.4) **is installed**,
  but the active developer dir points at CommandLineTools, so `xcodebuild` /
  `simctl` are unavailable until Xcode is selected and first-launched.
- ❌ **iOS runtimes** — none installed (`simctl list runtimes` is empty), so no
  iPhone simulators exist yet.
- ❌ **CocoaPods** — not installed. Required because the app uses
  `shared_preferences` (an iOS plugin with native pods).
- ⚠️ Android cmdline-tools / licenses, Chrome — not relevant to the iOS pass.

> These steps need `sudo` and large downloads, so they must be run interactively
> by the machine owner. They could not be completed by the agent autonomously.

## Fix it (exact commands)

```bash
# 1. Point the toolchain at the full Xcode and finish first launch.
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch

# 2. Accept the Xcode license.
sudo xcodebuild -license accept

# 3. Install an iOS simulator runtime (Xcode 16.4 ships iOS 18.x).
xcodebuild -downloadPlatform iOS
# (Alternatively, in Xcode: Settings > Components > get an iOS Simulator.)

# 4. Install CocoaPods (Homebrew is present on this machine).
brew install cocoapods
#   or: sudo gem install cocoapods

# 5. Verify everything is green for iOS.
flutter doctor -v
```

Expected after the above: `[✓] Xcode - develop for iOS and macOS` and at least
one iPhone simulator from `xcrun simctl list devices available`.

## Run the visual pass

Once the toolchain is ready, use the helper script from the repo root:

```bash
./scripts/ios_visual_pass.sh
```

It will: start the backend on `127.0.0.1:8000`, wait for `/v1/health`, boot an
iPhone simulator, and `flutter run` with
`--dart-define=TRADEWIZ_API_BASE_URL=http://127.0.0.1:8000/v1`.

Or do it manually:

```bash
# terminal 1 — backend
cd backend && source .venv/bin/activate
uvicorn app.main:app --host 127.0.0.1 --port 8000

# terminal 2 — app on a booted simulator
open -a Simulator
cd tradewiz
flutter run -d iPhone \
  --dart-define=TRADEWIZ_API_BASE_URL=http://127.0.0.1:8000/v1
```

`127.0.0.1` is reachable from the iOS Simulator (it shares the host network),
so no LAN IP is needed for the simulator. (A *physical* device would need the
Mac's LAN IP instead.)

## What to verify on screen

- **Dashboard** — top movers load; connection pill shows green **Live**.
- **Screener** — matches over the IDX/HKEX/KOSPI/KOSDAQ universe; **Live** pill;
  category + min-score filters re-query; "Showing X of Y" + Load more.
- **Analysis** — enter a symbol (e.g. `BBCA`, market IDX) → result card with a
  **Live** pill, weekly forecast, and a working "Save to Watchlist".
- **Watchlist** — saved item appears; tapping a row opens its analysis; survives
  an app relaunch (shared_preferences).

> Note: `/screen` fetches every symbol in a market's universe, so the first
> (cold) load can take a while on a slow connection. The backend caches OHLCV on
> disk (6h TTL) with a single-flight guard and an 8s per-symbol network timeout
> (`TRADEWIZ_YF_TIMEOUT`), so subsequent loads are fast.

## Automated equivalent (no simulator required)

The logic that drives those pills is verified headlessly by the live E2E test —
it asserts the app receives `DataSource.live` (not mock fallback) for
analyze/screen/predict_weekly against a real backend:

```bash
./scripts/e2e_smoke.sh
```

This is the agent-runnable proxy for the visual pass when the iOS toolchain or
network to data sources is unavailable.
