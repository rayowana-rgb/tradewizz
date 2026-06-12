import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/broker_app.dart';
import '../models/market.dart';

/// Outcome of a broker hand-off attempt (for callers + tests).
enum BrokerOpenOutcome {
  /// The broker app was opened (optionally deep-linked to the symbol).
  launchedApp,

  /// The app was not installed, so we opened the broker's Play Store page.
  openedStore,

  /// Nothing could be opened (no app, store launch failed).
  failed,
}

/// Thin seam over `url_launcher` so [BrokerService] is unit-testable without
/// platform channels. Production uses [UrlLauncherPlatformBridge].
abstract class BrokerLauncher {
  /// True when the OS can handle [uri] (≈ "is a handler installed").
  Future<bool> canOpen(Uri uri);

  /// Attempt to open [uri]; returns true on success.
  ///
  /// When [appLink] is true the launcher prefers handing an https link to a
  /// registered native app (iOS Universal Link / Android App Link) instead of
  /// a browser, so e.g. Stockbit opens in its app rather than Safari.
  Future<bool> open(
    Uri uri, {
    bool externalApplication = true,
    bool appLink = false,
  });

  /// Current platform flags (so the service can pick scheme vs package checks).
  bool get isAndroid;
  bool get isIOS;
}

/// Default [BrokerLauncher] backed by the real `url_launcher` plugin.
class UrlLauncherPlatformBridge implements BrokerLauncher {
  const UrlLauncherPlatformBridge();

  @override
  bool get isAndroid => !kIsWeb && Platform.isAndroid;

  @override
  bool get isIOS => !kIsWeb && Platform.isIOS;

  @override
  Future<bool> canOpen(Uri uri) => canLaunchUrl(uri);

  @override
  Future<bool> open(
    Uri uri, {
    bool externalApplication = true,
    bool appLink = false,
  }) async {
    if (appLink) {
      // iOS Universal Link / Android App Link: try to hand the https link to
      // the registered broker app (no Safari bounce). If no app claims it,
      // fall back to opening the link in the browser on the same symbol so
      // the user still lands on the right page instead of seeing an error.
      try {
        final opened = await launchUrl(
          uri,
          mode: LaunchMode.externalNonBrowserApplication,
        );
        if (opened) return true;
      } catch (_) {
        // No native handler — fall through to the browser launch below.
      }
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return launchUrl(
      uri,
      mode: externalApplication
          ? LaunchMode.externalApplication
          : LaunchMode.platformDefault,
    );
  }
}

/// Sink for the `broker_open_clicked` analytics event. Best-effort; a failure
/// here must never affect the hand-off. Kept generic so it can forward to the
/// existing activation metrics backend sink.
typedef BrokerAnalyticsSink = void Function(
  String event, {
  required Map<String, String> properties,
});

/// Coordinates the read-only broker hand-off:
///   1. emit `broker_open_clicked`,
///   2. detect whether the broker app is installed,
///   3. launch it (deep-linking to the symbol when supported), or
///   4. fall back to the broker's Play Store page.
///
/// This service NEVER places orders or moves money — it only opens another app.
class BrokerService {
  BrokerService({BrokerLauncher? launcher, this.analytics})
      : _launcher = launcher ?? const UrlLauncherPlatformBridge();

  final BrokerLauncher _launcher;
  final BrokerAnalyticsSink? analytics;

  static const String clickedEvent = 'broker_open_clicked';
  static const String confirmedEvent = 'broker_open_confirmed';
  static const String storeRedirectEvent = 'broker_store_redirect';

  /// Emit `broker_open_clicked` (intent). Call this when the user taps an
  /// "Open Broker" affordance, before any picker/confirmation is shown.
  void trackClicked({
    BrokerApp? broker,
    required String symbol,
    required Market market,
    required String source,
  }) {
    _emit(clickedEvent, {
      if (broker != null) 'broker': broker.id,
      'symbol': symbol.trim().toUpperCase(),
      'market': market.code,
      'source': source,
    });
  }

  /// Probe whether [broker] appears installed. On iOS this uses the custom URL
  /// scheme; on Android it relies on the app's launch scheme being resolvable
  /// (requires the matching `<queries>` entries in AndroidManifest.xml).
  Future<bool> isInstalled(BrokerApp broker) async {
    // HTTPS App Link brokers always resolve (app when registered, else web on
    // the same symbol), so the quick "open immediately" path applies to them.
    if (broker.usesHttpsDeepLink) return true;
    final probe = Uri.parse(broker.launchUrl);
    try {
      return await _launcher.canOpen(probe);
    } catch (_) {
      return false;
    }
  }

  /// Open [broker] for [symbol] in [market].
  ///
  /// Emits `broker_open_confirmed` when the installed app is launched, or
  /// `broker_store_redirect` when we fall back to the Play Store. The
  /// `broker_open_clicked` intent event is emitted separately by the UI via
  /// [trackClicked]. Returns the outcome.
  Future<BrokerOpenOutcome> open({
    required BrokerApp broker,
    required String symbol,
    required Market market,
    bool deepLink = true,
  }) async {
    // HTTPS App Link brokers (e.g. Stockbit) open straight to the symbol page
    // and resolve to the installed app when registered, or the web page on the
    // same symbol otherwise. Open the deep link directly without gating on a
    // custom-scheme install probe (which these brokers don't expose).
    if (deepLink && broker.usesHttpsDeepLink) {
      final uri = broker.openUri(symbol: symbol, market: market);
      // openUri may fall back to the app's custom scheme when the market has no
      // clean symbol page (e.g. Moomoo on an unlisted market). Only the real
      // https link uses the Universal/App Link launch mode.
      if (uri.scheme == 'https') {
        final ok = await _safeOpen(uri, appLink: true);
        final outcome =
            ok ? BrokerOpenOutcome.launchedApp : BrokerOpenOutcome.failed;
        _track(broker, symbol, market, ok, outcome);
        return outcome;
      }
      // Custom-scheme fallback: open the app, else send to the Play Store.
      final launched = await _safeOpen(uri);
      final outcome = launched
          ? BrokerOpenOutcome.launchedApp
          : (await _safeOpen(broker.playStoreUri)
              ? BrokerOpenOutcome.openedStore
              : BrokerOpenOutcome.failed);
      _track(broker, symbol, market, launched, outcome);
      return outcome;
    }

    final installed = await isInstalled(broker);

    BrokerOpenOutcome outcome;
    if (installed) {
      final useSymbolLink = deepLink && broker.supportsSymbolDeepLink;
      final uri = useSymbolLink
          ? broker.openUri(symbol: symbol, market: market)
          : Uri.parse(broker.launchUrl);
      final ok = await _safeOpen(uri);
      if (ok) {
        outcome = BrokerOpenOutcome.launchedApp;
      } else {
        // Deep link failed (e.g. unsupported path) — try the bare app, then
        // fall back to the store.
        final launched = useSymbolLink
            ? await _safeOpen(Uri.parse(broker.launchUrl))
            : false;
        outcome = launched
            ? BrokerOpenOutcome.launchedApp
            : (await _safeOpen(broker.playStoreUri)
                ? BrokerOpenOutcome.openedStore
                : BrokerOpenOutcome.failed);
      }
    } else {
      outcome = await _safeOpen(broker.playStoreUri)
          ? BrokerOpenOutcome.openedStore
          : BrokerOpenOutcome.failed;
    }

    _track(broker, symbol, market, installed, outcome);
    return outcome;
  }

  Future<bool> _safeOpen(Uri uri, {bool appLink = false}) async {
    try {
      return await _launcher.open(uri, appLink: appLink);
    } catch (_) {
      return false;
    }
  }

  void _track(
    BrokerApp broker,
    String symbol,
    Market market,
    bool installed,
    BrokerOpenOutcome outcome,
  ) {
    final props = {
      'broker': broker.id,
      'symbol': symbol.trim().toUpperCase(),
      'market': market.code,
      'installed': installed.toString(),
      'outcome': outcome.name,
    };
    switch (outcome) {
      case BrokerOpenOutcome.launchedApp:
        _emit(confirmedEvent, props);
      case BrokerOpenOutcome.openedStore:
        _emit(storeRedirectEvent, props);
      case BrokerOpenOutcome.failed:
        // No success event; nothing was opened.
        break;
    }
  }

  void _emit(String event, Map<String, String> properties) {
    final sink = analytics;
    if (sink == null) return;
    try {
      sink(event, properties: properties);
    } catch (_) {
      // Analytics must never break the hand-off.
    }
  }
}
