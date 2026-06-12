import '../models/market.dart';

/// A consumer broker *app* that TradeWizz can hand the user off to.
///
/// IMPORTANT — Play Store compliance:
/// This layer NEVER executes trades, places orders, or handles funds. It only
/// *opens* the third-party broker app (optionally deep-linking to a symbol) or,
/// if the app is not installed, opens that broker's Play Store page. TradeWizz
/// remains an analysis & research product; all trading happens inside the
/// broker's own app, under the broker's own authentication and disclosures.
enum BrokerApp {
  stockbit(
    id: 'stockbit',
    label: 'Stockbit',
    // Android package id (used for installed-detection + Play Store fallback).
    androidPackage: 'com.stockbit.android',
    // iOS custom URL scheme (for canLaunchUrl detection / launch on iOS).
    iosScheme: 'stockbit',
    // Optional deep link template. `{symbol}` is replaced with the bare ticker.
    // Stockbit exposes per-symbol pages via its app links.
    // Stockbit uses verified HTTPS App Links (not a custom scheme) for symbol
    // pages. When the app is installed it opens directly on the symbol;
    // otherwise it opens the web page on the same symbol. Verified 200 OK at
    // https://stockbit.com/symbol/<SYMBOL>. NOTE: the app does not parse a
    // query string, so no ?source=... — it would corrupt the ticker.
    deepLinkTemplate: 'https://stockbit.com/symbol/{symbol}',
    // Home/launch deep link when no symbol deep link is supported/desired.
    launchUrl: 'stockbit://',
  ),
  moomoo(
    id: 'moomoo',
    label: 'Moomoo',
    androidPackage: 'com.moomoo.trade',
    iosScheme: 'moomoo',
    // Moomoo's universal quote deep link; symbol passed bare.
    deepLinkTemplate: 'moomoo://quote/{symbol}',
    launchUrl: 'moomoo://',
  ),
  ajaib(
    id: 'ajaib',
    label: 'Ajaib',
    androidPackage: 'ajaib.co.id',
    iosScheme: 'ajaib',
    deepLinkTemplate: 'ajaib://stock/{symbol}',
    launchUrl: 'ajaib://',
  ),
  ipot(
    id: 'ipot',
    label: 'IPOT',
    androidPackage: 'com.indopremier.ipotgo',
    iosScheme: 'ipotgo',
    // IPOT does not document a public per-symbol deep link; launch the app.
    deepLinkTemplate: null,
    launchUrl: 'ipotgo://',
  ),
  miraeHots(
    id: 'mirae_hots',
    label: 'Mirae HOTS',
    androidPackage: 'com.miraeasset.global.id.hots',
    iosScheme: 'miraehots',
    deepLinkTemplate: null,
    launchUrl: 'miraehots://',
  );

  const BrokerApp({
    required this.id,
    required this.label,
    required this.androidPackage,
    required this.iosScheme,
    required this.deepLinkTemplate,
    required this.launchUrl,
  });

  /// Stable id used for persistence + analytics meta. Never localized.
  final String id;

  /// Display name shown in the picker / settings.
  final String label;

  /// Android application id, used both for installed-detection (intent query)
  /// and to build the Play Store fallback URL.
  final String androidPackage;

  /// iOS custom URL scheme used with `canLaunchUrl` for installed-detection.
  final String iosScheme;

  /// Optional `scheme://...{symbol}...` template. Null when the broker has no
  /// known public per-symbol deep link (we then just launch the app).
  final String? deepLinkTemplate;

  /// Fallback launch URL (the app's base scheme) when there is no symbol deep
  /// link or symbol deep-linking is not desired.
  final String launchUrl;

  /// Google Play Store listing for this broker (the not-installed fallback).
  Uri get playStoreUri =>
      Uri.parse('https://play.google.com/store/apps/details?id=$androidPackage');

  /// Whether this broker advertises a per-symbol deep link.
  bool get supportsSymbolDeepLink => deepLinkTemplate != null;

  /// Whether the per-symbol deep link is a verified HTTPS App Link (vs. a
  /// custom scheme). HTTPS links always launch (opening the app when installed
  /// and registered, else the web page on the same symbol), so for these we
  /// open the deep link directly instead of gating on install detection.
  bool get usesHttpsDeepLink =>
      deepLinkTemplate != null && deepLinkTemplate!.startsWith('https://');

  /// Build the best URI to *open* this broker for [symbol] in [market].
  ///
  /// Uses the per-symbol deep link when available, otherwise the plain launch
  /// URL. Returns the deep link as a [Uri]. The bare symbol is uppercased and
  /// URL-encoded; we intentionally do NOT pass quantities, prices, or any order
  /// parameters — this is a read-only hand-off, never a trade.
  Uri openUri({required String symbol, required Market market}) {
    final template = deepLinkTemplate;
    if (template == null) return Uri.parse(launchUrl);
    final sym = Uri.encodeComponent(symbol.trim().toUpperCase());
    return Uri.parse(template.replaceAll('{symbol}', sym));
  }

  /// Resolve a [BrokerApp] from its stable [id]; null when unknown.
  static BrokerApp? fromId(String? id) {
    if (id == null) return null;
    for (final b in BrokerApp.values) {
      if (b.id == id) return b;
    }
    return null;
  }
}
