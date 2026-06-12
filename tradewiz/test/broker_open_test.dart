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
    this.android = true,
  });

  /// URL schemes (e.g. 'stockbit') that report as installed via canOpen().
  final Set<String> installedSchemes;

  /// Uris (by toString()) that should fail to open.
  final Set<String> failOpenFor;

  final bool android;

  final List<Uri> canOpenCalls = [];
  final List<Uri> openCalls = [];

  @override
  bool get isAndroid => android;
  @override
  bool get isIOS => !android;

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
      final uri = BrokerApp.stockbit
          .openUri(symbol: 'bbca', market: Market.idx);
      expect(uri.toString(), 'stockbit://stocks/BBCA');
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
    test('installed broker deep-links to the symbol + emits analytics', () async {
      final fake = _FakeLauncher(installedSchemes: {'stockbit'});
      String? event;
      Map<String, String>? props;
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) {
          event = e;
          props = properties;
        },
      );

      final outcome = await svc.open(
        broker: BrokerApp.stockbit,
        symbol: 'bbca',
        market: Market.idx,
      );

      expect(outcome, BrokerOpenOutcome.launchedApp);
      expect(fake.openCalls.single.toString(), 'stockbit://stocks/BBCA');
      expect(event, 'broker_open_clicked');
      expect(props?['broker'], 'stockbit');
      expect(props?['symbol'], 'BBCA');
      expect(props?['market'], 'IDX');
      expect(props?['installed'], 'true');
      expect(props?['outcome'], 'launchedApp');
    });

    test('not-installed broker opens the Play Store fallback', () async {
      final fake = _FakeLauncher(installedSchemes: const {});
      String? outcomeMeta;
      final svc = BrokerService(
        launcher: fake,
        analytics: (e, {required properties}) =>
            outcomeMeta = properties['outcome'],
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
      expect(outcomeMeta, 'openedStore');
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
      expect(await svc.isInstalled(BrokerApp.stockbit), isFalse);
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
