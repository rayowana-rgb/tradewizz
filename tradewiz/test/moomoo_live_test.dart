import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/moomoo_live_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/moomoo_secret_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

import 'package:tradewiz/pages/account_page.dart';

/// In-memory secret persistence so tests never touch the Keychain.
class _MemSecret implements MoomooSecretPersistence {
  _MemSecret([this._v]);
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String secret) async => _v = secret;
  @override
  Future<void> clear() async => _v = null;
}

StockRepository _repoWith(MockClient client) => StockRepository(
      client: ApiClient(
        config: const AppConfig(
          baseUrl: 'https://test.tradewiz.app/v1',
          mockFallback: false,
        ),
        httpClient: client,
      ),
    );

Future<AuthStore> _auth(int uid) async {
  final auth = AuthStore();
  await auth.setSession('TOKEN',
      UserProfile(id: uid, email: 'u$uid@x.com', createdAt: '', updatedAt: ''));
  return auth;
}

Widget _wrap(Widget child, AuthStore auth, StockRepository repo) {
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth,
      child: EntitlementsScope(
        store: EntitlementsStore(repository: repo),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

/// A repo whose account/positions endpoints return a single position so the
/// positions list renders.
StockRepository _repoWithPositions() => _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 5000.0,
            'cash': 4000.0,
            'buying_power': 4800.0,
            'market_value': 1000.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(
          jsonEncode({
            'positions': [
              {
                'code': 'US.INTC',
                'symbol': 'INTC',
                'quantity': 10.0,
                'can_sell_qty': 10.0,
                'cost_price': 30.0,
                'last_price': 33.5,
                'pl_val': 35.0,
                'pl_ratio': 0.1167,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('owner uid 2 sees the Moomoo Live entry on Account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_moomoo_live_link')), 200,
        scrollable: list);
    expect(find.byKey(const Key('account_moomoo_live_link')), findsOneWidget);
  });

  testWidgets('non-owner uid does NOT see the Moomoo Live entry',
      (tester) async {
    final auth = await _auth(1);
    final repo = _repoWith(MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_moomoo_live_link')), findsNothing);
  });

  testWidgets('no secret -> setup card; entering secret loads account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    var accountCalls = 0;
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        accountCalls++;
        // Assert the secret header is forwarded.
        expect(req.headers['X-Moomoo-Secret'], 'topsecret');
        return http.Response(
          jsonEncode({
            'total_assets': 5000.0,
            'cash': 4000.0,
            'buying_power': 4800.0,
            'market_value': 1000.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({'positions': []}), 200);
      }
      return http.Response('{}', 200);
    }));

    final store = MoomooSecretStore(persistence: _MemSecret());
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // No secret yet -> setup card shown, no account loaded.
    expect(find.byKey(const Key('moomoo_setup_card')), findsOneWidget);
    expect(accountCalls, 0);

    // Enter the secret via the setup dialog.
    await tester.tap(find.byKey(const Key('moomoo_setup_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moomoo_secret_field')), 'topsecret');
    await tester.tap(find.byKey(const Key('moomoo_secret_save')));
    await tester.pumpAndSettle();

    // Account now loads (header card present, header call made).
    expect(find.byKey(const Key('moomoo_account_card')), findsOneWidget);
    expect(accountCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('shows total unrealized P/L summed from positions',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 5000.0,
            'cash': 4000.0,
            'buying_power': 4800.0,
            'market_value': 1000.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(
          jsonEncode({
            'positions': [
              {
                'code': 'US.INTC',
                'symbol': 'INTC',
                'quantity': 10.0,
                'can_sell_qty': 10.0,
                'cost_price': 30.0,
                'last_price': 33.5,
                'pl_val': 35.0,
                'pl_ratio': 0.1167,
              },
              {
                'code': 'US.AMD',
                'symbol': 'AMD',
                'quantity': 5.0,
                'can_sell_qty': 5.0,
                'cost_price': 100.0,
                'last_price': 96.0,
                'pl_val': -20.0,
                'pl_ratio': -0.04,
              },
            ],
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // Net P/L = 35 - 20 = +15.00 over 800 cost basis = +1.88%.
    expect(find.text('Unrealized P/L'), findsOneWidget);
    expect(find.textContaining('+\$15.00'), findsWidgets);
    // Per-position tiles render with avg cost.
    expect(find.byKey(const Key('moomoo_pos_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_AMD')), findsOneWidget);
  });

  testWidgets('hide positions toggle hides tiles and persists',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('moomoo_pos_INTC')), findsOneWidget);

    await tester.tap(find.byKey(const Key('moomoo_toggle_positions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_pos_INTC')), findsNothing);
    expect(find.text('Positions hidden.'), findsOneWidget);

    // Preference persisted.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tradewizz.moomoo.hidePositions'), true);

    // Rebuild a fresh page: hidden state restored from prefs.
    final store2 = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store2), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_pos_INTC')), findsNothing);
  });

  testWidgets('portfolio manager card renders risk + recommendations',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 1000.0,
            'cash': 50.0,
            'buying_power': 50.0,
            'market_value': 950.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({'positions': []}), 200);
      }
      if (req.url.path.endsWith('/broker/moomoo/manager')) {
        return http.Response(
          jsonEncode({
            'risk_level': 'HIGH',
            'concentration_score': 5.0,
            'diversification_score': 20.0,
            'cash_pct': 5.0,
            'largest_position_pct': 95.0,
            'holdings_count': 2,
            'recommendations': [
              {
                'kind': 'concentration',
                'severity': 'critical',
                'title': 'High concentration',
                'message': 'AAA is 95% of holdings value.',
                'symbol': 'AAA',
              },
            ],
            'live': true,
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('moomoo_manager_card')), findsOneWidget);
    expect(find.text('HIGH risk'), findsOneWidget);
    expect(find.byKey(const Key('moomoo_rec_concentration')), findsOneWidget);
    expect(find.textContaining('High concentration'), findsOneWidget);
  });

  testWidgets('order ticket: comma is stripped from the quantity field',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moomoo_new_order')));
    await tester.pumpAndSettle();

    // Typing a comma should be filtered out (only digits + one dot allowed).
    await tester.enterText(
        find.byKey(const Key('moomoo_qty_field')), '0,001');
    await tester.pump();
    final field = tester.widget<TextField>(
        find.byKey(const Key('moomoo_qty_field')));
    expect(field.controller!.text, '0001');

    // A clean fractional value with a dot is preserved.
    await tester.enterText(
        find.byKey(const Key('moomoo_qty_field')), '0.001');
    await tester.pump();
    expect(field.controller!.text, '0.001');
  });
}
