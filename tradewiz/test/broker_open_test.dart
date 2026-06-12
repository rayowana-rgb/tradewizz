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
  });

  /// URL schemes (e.g. 'stockbit') that report as installed via canOpen().
  final Set<String> installedSchemes;

  /// Uris (by toString()) that should fail to open.
  final Set<String> failOpenFor;

  final List<Uri> canOpenCalls = [];
  final List<Uri> openCalls = [];

  @override
  bool get isAndroid => true;
  @override
  bool get isIOS => false;

  @override
  Future<bool> canOpen(Uri uri) async {
    canOpenCalls.add(uri);
    return installedSchemes.contains(uri.scheme);
  }

  @override
  Future<bool> open(Uri uri, {bool externalApplication = true}) async {
    openCalls.add(uri);
    return !failOpenFor.contains(uri.toString());
  }
}

void main() {
  group('BrokerApp model', () {
    test('catalog has all five required brokers', () {
      final ids = BrokerApp.values.map((b) => b.id).toSet();
      expect(
        ids,
        containsAll(<String>['stockbit', 'moomoo', 'ajaib', 'ipot', 'mirae_hots']),
      );
    });

    test('symbol deep link uppercases + encodes the bare ticker', () {
      final uri = BrokerApp.moomoo
          .openUri(symbol: 'aapl', market: Market.us);
      expect(uri.toString(), 'moomoo://quote/AAPL');
    });

    test('Stockbit uses a verified HTTPS App Link to the symbol page', () {
      final uri = BrokerApp.stockbit
          .openUri(symbol: 'bbca', market: Market.idx);
      expect(uri.toString(),
          'https://stockbit.com/symbol/BBCA?source=deeplink');
      expect(BrokerApp.stockbit.usesHttpsDeepLink, isTrue);
      expect(BrokerApp.moomoo.usesHttpsDeepLink, isFalse);
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
      expect(uri.toString(), 'moomoo://quote/AAPL');
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
          'https://stockbit.com/symbol/BBCA?source=deeplink');
      // No custom-scheme install probe for HTTPS App Link brokers.
      expect(fake.canOpenCalls, isEmpty);
      expect(events, ['broker_open_confirmed']);
    });

    test('installed broker deep-links + emits broker_open_confirmed', () async {
      final fake = _FakeLauncher(installedSchemes: {'moomoo'});
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
        broker: BrokerApp.moomoo,
        symbol: 'bbca',
        market: Market.idx,
      );

      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.single.toString(), 'moomoo://quote/BBCA');
      expect(events, ['broker_open_confirmed']);
      expect(props?['broker'], 'moomoo');
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
        installedSchemes: {'moomoo'},
        failOpenFor: {'moomoo://quote/AAPL'},
      );
      final svc = BrokerService(launcher: fake);

      final outcome = await svc.open(
        broker: BrokerApp.moomoo,
        symbol: 'AAPL',
        market: Market.us,
      );

      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.first.toString(), 'moomoo://quote/AAPL');
      expect(fake.openCalls.last.toString(), 'moomoo://');
    });

    test('isInstalled reflects the launcher canOpen result', () async {
      final fake = _FakeLauncher(installedSchemes: {'ajaib'});
      final svc = BrokerService(launcher: fake);
      expect(await svc.isInstalled(BrokerApp.ajaib), isTrue);
      expect(await svc.isInstalled(BrokerApp.moomoo), isFalse);
      // HTTPS App Link brokers always resolve, so they report installed.
      expect(await svc.isInstalled(BrokerApp.stockbit), isTrue);
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
