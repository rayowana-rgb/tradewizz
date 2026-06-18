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
    androidPackage: 'com.moomoo.trade.universal',
    iosScheme: 'moomoo',
    // Moomoo exposes per-symbol pages as HTTPS App Links of the form
    // https://www.moomoo.com/stock/<SYMBOL>-<MARKET> (verified 200 for
    // US/JP/SG). The market suffix comes from Market.moomooSuffix; when it is
    // null (market not listed by Moomoo) openUri() falls back to launching the
    // app. {market} is substituted in openUri(), not here.
    deepLinkTemplate: 'https://www.moomoo.com/stock/{symbol}-{market}',
    launchUrl: 'moomoo://',
    // Moomoo ships regional builds (global "moomoo", SG, and the FUTU/moomoo
    // lineage) that register different custom URL schemes. iOS Universal
    // Links to www.moomoo.com don't reliably open these regional apps (they
    // bounce to Safari), so on iOS we try each known scheme before falling
    // back to the https link. Every scheme listed here MUST also appear in
    // ios/Runner/Info.plist under LSApplicationQueriesSchemes, otherwise iOS
    // refuses to even attempt the open.
    iosSchemeCandidates: ['moomoo', 'futubull', 'moomoosg', 'ftnntrade'],
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
  ),
  ibkr(
    id: 'ibkr',
    label: 'IBKR',
    // Interactive Brokers' IBKR Mobile app.
    androidPackage: 'atws.app',
    iosScheme: 'ibkr',
    // IBKR does not document a public per-symbol deep link or symbol web page,
    // so we intentionally do NOT guess one (a bad link would corrupt the
    // ticker, as we saw with Stockbit). Open the app instead.
    deepLinkTemplate: null,
    launchUrl: 'ibkr://',
  );

  const BrokerApp({
    required this.id,
    required this.label,
    required this.androidPackage,
    required this.iosScheme,
    required this.deepLinkTemplate,
    required this.launchUrl,
    this.iosSchemeCandidates = const [],
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

  /// Extra iOS custom URL schemes to try (in order) when this broker uses an
  /// https Universal Link that may not open the installed (regional) app. Each
  /// scheme must also be whitelisted in Info.plist's LSApplicationQueriesSchemes.
  /// Empty for brokers that have a single, reliable scheme.
  final List<String> iosSchemeCandidates;

  /// Ordered list of `scheme://` launch URIs to try opening on iOS before
  /// falling back to the https link. Starts with [launchUrl]'s scheme, then
  /// any [iosSchemeCandidates], de-duplicated.
  List<Uri> get iosLaunchCandidates {
    final schemes = <String>[];
    final base = Uri.tryParse(launchUrl)?.scheme;
    if (base != null && base.isNotEmpty) schemes.add(base);
    for (final s in iosSchemeCandidates) {
      if (!schemes.contains(s)) schemes.add(s);
    }
    return [for (final s in schemes) Uri.parse('$s://')];
  }

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

    // Moomoo symbol pages require a market suffix (e.g. AAPL-US). When the
    // market isn't listed by Moomoo there is no clean symbol page, so launch
    // the app rather than build a URL that would 404.
    if (template.contains('{market}')) {
      final suffix = market.moomooSuffix;
      if (suffix == null) return Uri.parse(launchUrl);
      return Uri.parse(
        template.replaceAll('{symbol}', sym).replaceAll('{market}', suffix),
      );
    }

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
