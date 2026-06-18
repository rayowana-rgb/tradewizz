import 'package:flutter_test/flutter_test.dart';
import 'package:tradewiz/models/broker_app.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/services/broker_launcher.dart';

/// A fake [BrokerLauncher] that records calls and is fully scripted, so the
/// broker hand-off can be tested without platform channels.
class _FakeLauncher implements BrokerLauncher {
  _FakeLauncher({
    this.installedSchemes = const {},
    this.failOpenFor = const {},
    this.ios = false,
  });

  /// Pretend to be iOS (so the custom-scheme-first path is exercised).
  final bool ios;

  /// URL schemes (e.g. 'stockbit') that report as installed via canOpen().
  final Set<String> installedSchemes;

  /// Uris (by toString()) that should fail to open.
  final Set<String> failOpenFor;

  final List<Uri> canOpenCalls = [];
  final List<Uri> openCalls = [];

  @override
  bool get isAndroid => !ios;
  @override
  bool get isIOS => ios;

  @override
  Future<bool> canOpen(Uri uri) async {
    canOpenCalls.add(uri);
    return installedSchemes.contains(uri.scheme);
  }

  @override
  Future<bool> open(
    Uri uri, {
    bool externalApplication = true,
    bool appLink = false,
  }) async {
    openCalls.add(uri);
    return !failOpenFor.contains(uri.toString());
  }
}

void main() {
  group('BrokerApp model', () {
    test('catalog has all required brokers', () {
      final ids = BrokerApp.values.map((b) => b.id).toSet();
      expect(
        ids,
        containsAll(<String>[
          'stockbit',
          'moomoo',
          'ajaib',
          'ipot',
          'mirae_hots',
          'ibkr',
        ]),
      );
    });

    test('symbol deep link uppercases + encodes the bare ticker', () {
      final uri = BrokerApp.ajaib
          .openUri(symbol: 'aapl', market: Market.us);
      expect(uri.toString(), 'ajaib://stock/AAPL');
    });

    test('Stockbit uses a verified HTTPS App Link to the symbol page', () {
      final uri = BrokerApp.stockbit
          .openUri(symbol: 'bbca', market: Market.idx);
      expect(uri.toString(),
          'https://stockbit.com/symbol/BBCA');
      expect(BrokerApp.stockbit.usesHttpsDeepLink, isTrue);
      expect(BrokerApp.ajaib.usesHttpsDeepLink, isFalse);
    });

    test('Moomoo uses an HTTPS App Link with the market suffix', () {
      // Verified format: https://www.moomoo.com/stock/<SYMBOL>-<MARKET>.
      expect(
        BrokerApp.moomoo.openUri(symbol: 'aapl', market: Market.us).toString(),
        'https://www.moomoo.com/stock/AAPL-US',
      );
      expect(
        BrokerApp.moomoo
            .openUri(symbol: '7203', market: Market.japan)
            .toString(),
        'https://www.moomoo.com/stock/7203-JP',
      );
      expect(BrokerApp.moomoo.usesHttpsDeepLink, isTrue);
    });

    test('Moomoo falls back to the app when the market is not listed', () {
      // India has no Moomoo symbol page (moomooSuffix == null) -> launch app.
      final uri =
          BrokerApp.moomoo.openUri(symbol: 'RELIANCE', market: Market.india);
      expect(uri.toString(), 'moomoo://');
    });

    test('IBKR opens the app (no guessed per-symbol deep link)', () {
      final uri =
          BrokerApp.ibkr.openUri(symbol: 'AAPL', market: Market.us);
      expect(uri.toString(), 'ibkr://');
      expect(BrokerApp.ibkr.supportsSymbolDeepLink, isFalse);
    });

    test('brokers without a deep link fall back to the launch url', () {
      final uri =
          BrokerApp.ipot.openUri(symbol: 'BBRI', market: Market.idx);
      expect(uri.toString(), 'ipotgo://');
      expect(BrokerApp.ipot.supportsSymbolDeepLink, isFalse);
      expect(BrokerApp.stockbit.supportsSymbolDeepLink, isTrue);
    });

    test('deep link never carries order params (read-only hand-off)', () {
      final uri = BrokerApp.moomoo
          .openUri(symbol: 'AAPL', market: Market.us);
      expect(uri.toString(), 'https://www.moomoo.com/stock/AAPL-US');
      expect(uri.toString(), isNot(contains('qty')));
      expect(uri.toString(), isNot(contains('price')));
      expect(uri.toString(), isNot(contains('order')));
      expect(uri.toString(), isNot(contains('side')));
    });

    test('play store uri targets the broker package', () {
      expect(
        BrokerApp.ajaib.playStoreUri.toString(),
        'https://play.google.com/store/apps/details?id=ajaib.co.id',
      );
    });

    test('fromId resolves and rejects unknowns', () {
      expect(BrokerApp.fromId('moomoo'), BrokerApp.moomoo);
      expect(BrokerApp.fromId('nope'), isNull);
      expect(BrokerApp.fromId(null), isNull);
    });
  });

  group('BrokerService hand-off', () {
    test('Stockbit HTTPS deep link opens the symbol without an install probe',
        () async {
      final fake = _FakeLauncher(installedSchemes: const {});
      final events = <String>[];
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) => events.add(e),
      );
      final outcome = await svc.open(
        broker: BrokerApp.stockbit,
        symbol: 'bbca',
        market: Market.idx,
      );
      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.single.toString(),
          'https://stockbit.com/symbol/BBCA');
      // No custom-scheme install probe for HTTPS App Link brokers.
      expect(fake.canOpenCalls, isEmpty);
      expect(events, ['broker_open_confirmed']);
    });

    test('installed broker deep-links + emits broker_open_confirmed', () async {
      final fake = _FakeLauncher(installedSchemes: {'ajaib'});
      final events = <String>[];
      Map<String, String>? props;
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) {
          events.add(e);
          props = properties;
        },
      );

      final outcome = await svc.open(
        broker: BrokerApp.ajaib,
        symbol: 'bbca',
        market: Market.idx,
      );

      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.single.toString(), 'ajaib://stock/BBCA');
      expect(events, ['broker_open_confirmed']);
      expect(props?['broker'], 'ajaib');
      expect(props?['symbol'], 'BBCA');
      expect(props?['market'], 'IDX');
      expect(props?['installed'], 'true');
      expect(props?['outcome'], 'launchedApp');
    });

    test('not-installed broker -> Play Store + broker_store_redirect', () async {
      final fake = _FakeLauncher(installedSchemes: const {});
      final events = <String>[];
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) => events.add(e),
      );

      final outcome = await svc.open(
        broker: BrokerApp.miraeHots,
        symbol: 'BBRI',
        market: Market.idx,
      );

      expect(outcome, BrokerOpenOutcome.openedStore);
      expect(
        fake.openCalls.single.toString(),
        'https://play.google.com/store/apps/details?id=com.miraeasset.global.id.hots',
      );
      expect(events, ['broker_store_redirect']);
    });

    test('trackClicked emits broker_open_clicked with source', () {
      final events = <String>[];
      Map<String, String>? props;
      final svc = BrokerService(
        launcher: _FakeLauncher(),
        analytics: (e, {required properties}) {
          events.add(e);
          props = properties;
        },
      );
      svc.trackClicked(
        broker: BrokerApp.moomoo,
        symbol: 'aapl',
        market: Market.us,
        source: 'screener',
      );
      expect(events, ['broker_open_clicked']);
      expect(props?['broker'], 'moomoo');
      expect(props?['symbol'], 'AAPL');
      expect(props?['source'], 'screener');
    });

    test('failed open emits no success event', () async {
      final fake = _FakeLauncher(
        installedSchemes: const {},
        failOpenFor: {
          'https://play.google.com/store/apps/details?id=ajaib.co.id',
        },
      );
      final events = <String>[];
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) => events.add(e),
      );
      final outcome = await svc.open(
        broker: BrokerApp.ajaib,
        symbol: 'BBRI',
        market: Market.idx,
      );
      expect(outcome, BrokerOpenOutcome.failed);
      expect(events, isEmpty);
    });

    test('deep-link failure falls back to launching the bare app', () async {
      final fake = _FakeLauncher(
        installedSchemes: {'ajaib'},
        failOpenFor: {'ajaib://stock/AAPL'},
      );
      final svc = BrokerService(launcher: fake);

      final outcome = await svc.open(
        broker: BrokerApp.ajaib,
        symbol: 'AAPL',
        market: Market.us,
      );

      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.first.toString(), 'ajaib://stock/AAPL');
      expect(fake.openCalls.last.toString(), 'ajaib://');
    });

    test('Moomoo HTTPS deep link opens the symbol without an install probe',
        () async {
      final fake = _FakeLauncher(installedSchemes: const {});
      final events = <String>[];
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) => events.add(e),
      );
      final outcome = await svc.open(
        broker: BrokerApp.moomoo,
        symbol: 'aapl',
        market: Market.us,
      );
      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.single.toString(),
          'https://www.moomoo.com/stock/AAPL-US');
      expect(fake.canOpenCalls, isEmpty);
      expect(events, ['broker_open_confirmed']);
    });

    test(
        'iOS: installed Moomoo opens via custom scheme, not the https '
        'Universal Link (avoids the Safari bounce)', () async {
      // The Moomoo app is installed (its moomoo:// scheme resolves). On iOS we
      // should open the app via the custom scheme instead of the https link,
      // because iOS Universal Links silently fall back to Safari when the
      // app↔domain association doesn't match (the reported MOMO SG bug).
      final fake = _FakeLauncher(installedSchemes: {'moomoo'}, ios: true);
      final events = <String>[];
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) => events.add(e),
      );
      final outcome = await svc.open(
        broker: BrokerApp.moomoo,
        symbol: 'D05',
        market: Market.singapore,
      );
      expect(outcome, BrokerOpenOutcome.launchedApp);
      // Opened the custom scheme directly (no canOpen gate, no https open).
      expect(fake.openCalls.single.toString(), 'moomoo://');
      expect(events, ['broker_open_confirmed']);
    });

    test('iOS: Moomoo not installed falls back to the https Universal Link',
        () async {
      // The custom scheme fails to open (no app) -> fall back to https.
      final fake = _FakeLauncher(
        installedSchemes: const {},
        failOpenFor: {'moomoo://'},
        ios: true,
      );
      final svc = BrokerService(launcher: fake);
      final outcome = await svc.open(
        broker: BrokerApp.moomoo,
        symbol: 'D05',
        market: Market.singapore,
      );
      expect(outcome, BrokerOpenOutcome.launchedApp);
      // Tried the custom scheme first, then opened the https link.
      expect(fake.openCalls.first.toString(), 'moomoo://');
      expect(fake.openCalls.last.toString(),
          'https://www.moomoo.com/stock/D05-SG');
    });

    test('isInstalled reflects the launcher canOpen result', () async {
      final fake = _FakeLauncher(installedSchemes: {'ajaib'});
      final svc = BrokerService(launcher: fake);
      expect(await svc.isInstalled(BrokerApp.ajaib), isTrue);
      // IBKR has no HTTPS link + isn't in installedSchemes -> not installed.
      expect(await svc.isInstalled(BrokerApp.ibkr), isFalse);
      // HTTPS App Link brokers always resolve, so they report installed.
      expect(await svc.isInstalled(BrokerApp.stockbit), isTrue);
      expect(await svc.isInstalled(BrokerApp.moomoo), isTrue);
    });
  });

  group('preferred broker persistence', () {
    test('round-trips through UserPrefs json', () {
      const prefs = UserPrefs(preferredBrokerId: 'moomoo');
      final restored = UserPrefs.fromJson(prefs.toJson());
      expect(restored.preferredBrokerId, 'moomoo');
    });

    test('copyWith can clear the preference', () {
      const prefs = UserPrefs(preferredBrokerId: 'ajaib');
      final cleared = prefs.copyWith(clearPreferredBroker: true);
      expect(cleared.preferredBrokerId, isNull);
    });

    test('defaults to null when absent', () {
      final restored = UserPrefs.fromJson(const {});
      expect(restored.preferredBrokerId, isNull);
    });
  });
}
