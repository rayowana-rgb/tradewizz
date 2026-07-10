# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

## TradeWizz iOS install targets

ALWAYS install every new TradeWizz build to BOTH of the user's physical iPhones:

- **iPhone 16e** — model `iPhone17,5`, UDID `00008140-001A5D512253801C` (iOS 26.5.2)
- **iPhone Air** — model `iPhone18,4`, UDID `00008150-000218DA3A40401C` (iOS 26.5.1)

Team `9D4M3NN778`, bundle `com.tradewiz.tradewiz`.
Note: both devices show as "Putu's iPhone" in Xcode — disambiguate by model/iOS.

### MOST RELIABLE INSTALL (use this): build once, then devicectl install
`flutter run --release -d <UDID>` builds fine but its WIRELESS install/launch
step frequently fails with "may need to be unlocked" even when unlocked. The
reliable path is to let flutter BUILD the app, then install the built .app with
devicectl to each device:
```
cd tradewiz
flutter run --release -d <any-UDID>   # let it build; install step may fail — that's OK
xcrun devicectl device install app --device 00008140-001A5D512253801C build/ios/iphoneos/Runner.app  # 16e
xcrun devicectl device install app --device 00008150-000218DA3A40401C build/ios/iphoneos/Runner.app  # Air
```
devicectl succeeded on BOTH phones over the tunnel in seconds when `flutter run`
could not. (Confirmed 2026-07-10, build 23.)
Still: iPhone unlocked + screen ON + same Wi-Fi helps; may need a couple tries.

---

Add whatever helps you do your job. This is your cheat sheet.

## Related

- [Agent workspace](/concepts/agent-workspace)
