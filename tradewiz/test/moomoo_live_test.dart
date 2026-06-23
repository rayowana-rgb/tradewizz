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
      // No analytics in this fixture: 404 so the advisory cards are skipped
      // and the position tile stays in the visible viewport.
      if (req.url.path.contains('/broker/moomoo/manager') ||
          req.url.path.contains('/broker/moomoo/health') ||
          req.url.path.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
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
      if (req.url.path.contains('/broker/moomoo/manager') ||
          req.url.path.contains('/broker/moomoo/health') ||
          req.url.path.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
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
    expect(find.byKey(const Key('moomoo_rec_concentration_0')), findsOneWidget);
    expect(find.textContaining('High concentration'), findsOneWidget);

    // Manager toggle hides only the recommendations list; header stays.
    await tester.tap(find.byKey(const Key('moomoo_toggle_manager')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_manager_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_rec_concentration_0')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tradewizz.moomoo.hideManager'), isTrue);
  });

  testWidgets('order ticket: a typed decimal comma becomes a dot',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moomoo_new_order')));
    await tester.pumpAndSettle();

    // A decimal comma (Indonesian/EU keyboards) is normalised to a dot so the
    // odd-lot quantity parses as 0.001 instead of collapsing to a whole number.
    await tester.enterText(
        find.byKey(const Key('moomoo_qty_field')), '0,001');
    await tester.pump();
    final field = tester.widget<TextField>(
        find.byKey(const Key('moomoo_qty_field')));
    expect(field.controller!.text, '0.001');

    // A clean fractional value with a dot is preserved.
    await tester.enterText(
        find.byKey(const Key('moomoo_qty_field')), '0.001');
    await tester.pump();
    expect(field.controller!.text, '0.001');

    // Only the first separator is kept (extra dots/commas dropped).
    await tester.enterText(
        find.byKey(const Key('moomoo_qty_field')), '0,0,1');
    await tester.pump();
    expect(field.controller!.text, '0.01');
  });

  testWidgets('analytics toggles hide only the per-stock list, not the card',
      (tester) async {
    // Tall viewport so the ListView builds all analytics sections at once.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(_analyticsClient());
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    // All three analytics cards render; rebalance shows its per-stock tile.
    expect(find.byKey(const Key('moomoo_health_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_rebalance_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsOneWidget);
    expect(find.text('Position concentration too high in INTC (100%).'),
        findsOneWidget);

    // Hide the Health detail lines: the CARD stays, only the warning lines go.
    await tester.tap(find.byKey(const Key('moomoo_toggle_health')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_health_card')), findsOneWidget);
    expect(find.text('Position concentration too high in INTC (100%).'),
        findsNothing);

    // Hide the Rebalance actions: the CARD stays, only the per-stock tiles go.
    await tester.tap(find.byKey(const Key('moomoo_toggle_rebalance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_rebalance_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsNothing);
    expect(find.text('Rebalancing actions hidden.'), findsOneWidget);

    // The hide flags are persisted under the documented SharedPreferences keys.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('tradewizz.moomoo.hideHealth'), isTrue);
    expect(prefs.getBool('tradewizz.moomoo.hideRebalance'), isTrue);
  });

  testWidgets('analytics hide flags restore from prefs on a fresh launch',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Health + rebalance were hidden in a previous session.
    SharedPreferences.setMockInitialValues({
      'tradewizz.moomoo.hideHealth': true,
      'tradewizz.moomoo.hideRebalance': true,
    });

    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(_analyticsClient());
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    // Cards still render; only the per-stock lists stay collapsed from prefs.
    expect(find.byKey(const Key('moomoo_health_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_rebalance_card')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_manager_card')), findsOneWidget);
    // Hidden detail: health warning line gone, rebalance tile gone.
    expect(find.text('Position concentration too high in INTC (100%).'),
        findsNothing);
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsNothing);
    expect(find.text('Rebalancing actions hidden.'), findsOneWidget);
  });
}

/// Mock client that serves account + positions + all three analytics endpoints
/// with realistic (non-empty) shapes.
MockClient _analyticsClient() => MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 1000.0,
            'cash': 200.0,
            'buying_power': 200.0,
            'market_value': 800.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (p.endsWith('/broker/moomoo/positions')) {
        return http.Response(
          jsonEncode({
            'positions': [
              {
                'code': 'US.INTC', 'symbol': 'INTC', 'quantity': 2.0,
                'can_sell_qty': 2.0, 'cost_price': 130.0, 'last_price': 134.0,
                'pl_val': 8.0, 'pl_ratio': 0.03,
              },
            ],
          }),
          200,
        );
      }
      if (p.endsWith('/broker/moomoo/manager')) {
        return http.Response(
          jsonEncode({
            'risk_level': 'MODERATE',
            'concentration_score': 50.0,
            'diversification_score': 10.0,
            'cash_pct': 20.0,
            'largest_position_pct': 100.0,
            'holdings_count': 1,
            'recommendations': [],
            'live': true,
          }),
          200,
        );
      }
      if (p.endsWith('/broker/moomoo/health')) {
        return http.Response(
          jsonEncode({
            'user_id': 0,
            'generated_at': '',
            'health_score': 68.0,
            'rating': 'Fair',
            'components': {
              'diversification': 10.0,
              'concentration_risk': 0.0,
              'liquidity': 70.0,
              'quality': 62.0,
              'sector_exposure': 50.0,
            },
            'warnings': ['Position concentration too high in INTC (100%).'],
            'strengths': [],
            'exit_warnings': [],
            'market_exposure': {'US': 100.0},
            'positions': [
              {
                'symbol': 'INTC', 'market': 'US', 'quantity': 2.0,
                'quality_score': 62.0, 'rating': 'Solid', 'note': '',
              },
            ],
            'simulated': false,
          }),
          200,
        );
      }
      if (p.endsWith('/broker/moomoo/rebalance')) {
        return http.Response(
          jsonEncode({
            'user_id': 0,
            'generated_at': '',
            'profile': 'Balanced',
            'portfolio_score': 68.0,
            'cash_allocation': 20.0,
            'actions': [
              {
                'symbol': 'INTC', 'market': 'US', 'name': 'INTC',
                'action': 'REDUCE', 'reason': 'Single-name weight too high.',
                'current_weight': 100.0, 'target_weight': 25.0,
                'priority': 'HIGH', 'score': 62.0, 'quality_score': 62.0,
              },
            ],
            'summary': '1 action suggested.',
            'warnings': [],
            'high_priority_count': 1,
            'estimated_score_improvement': 8.0,
            'simulated': false,
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    });
