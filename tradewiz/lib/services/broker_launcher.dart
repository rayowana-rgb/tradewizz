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
  Future<bool> open(Uri uri, {bool externalApplication = true});

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
  Future<bool> open(Uri uri, {bool externalApplication = true}) => launchUrl(
        uri,
        mode: externalApplication
            ? LaunchMode.externalApplication
            : LaunchMode.platformDefault,
      );
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

  static const String openEvent = 'broker_open_clicked';

  /// Probe whether [broker] appears installed. On iOS this uses the custom URL
  /// scheme; on Android it relies on the app's launch scheme being resolvable
  /// (requires the matching `<queries>` entries in AndroidManifest.xml).
  Future<bool> isInstalled(BrokerApp broker) async {
    final probe = Uri.parse(broker.launchUrl);
    try {
      return await _launcher.canOpen(probe);
    } catch (_) {
      return false;
    }
  }

  /// Open [broker] for [symbol] in [market].
  ///
  /// Emits `broker_open_clicked` first (with the resolved outcome added once
  /// known), then launches the app or the store fallback. Returns the outcome.
  Future<BrokerOpenOutcome> open({
    required BrokerApp broker,
    required String symbol,
    required Market market,
    bool deepLink = true,
  }) async {
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

  Future<bool> _safeOpen(Uri uri) async {
    try {
      return await _launcher.open(uri);
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
    final sink = analytics;
    if (sink == null) return;
    try {
      sink(openEvent, properties: {
        'broker': broker.id,
        'symbol': symbol.trim().toUpperCase(),
        'market': market.code,
        'installed': installed.toString(),
        'outcome': outcome.name,
      });
    } catch (_) {
      // Analytics must never break the hand-off.
    }
  }
}
