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
import 'package:tradewiz/services/keep_awake.dart';
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

// Two positions with deliberately opposite P/L and weight rankings so the sort
// chips can be told apart:
//   INTC: pl_val +35, weight 10*33.5 = 335
//   AMD : pl_val -20, weight  5*96.0 = 480
// => by P/L high->low: INTC, AMD; by weight high->low: AMD, INTC.
StockRepository _repoWithTwoPositions() => _repoWith(MockClient((req) async {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Wakelock needs a platform channel that isn't wired up in unit tests.
    KeepAwake.debugToggle = (_) async {};
  });
  tearDown(() => KeepAwake.debugToggle = null);

  testWidgets('owner uid 2 sees the Moomoo Live entry on Account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((_) async => http.Response('{}', 200)));
    // Empty secret -> no live overlay; stays on the simulated portfolio.
    final secret = MoomooSecretStore(persistence: _MemSecret());
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, moomooSecret: secret), auth, repo));
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
    final secret = MoomooSecretStore(persistence: _MemSecret());
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, moomooSecret: secret), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_moomoo_live_link')), findsNothing);
  });

  testWidgets(
      'owner with a configured secret sees the LIVE Moomoo portfolio on Account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    // Account + one position from the LIVE bridge.
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        expect(req.headers['X-Moomoo-Secret'], 'topsecret');
        return http.Response(
          jsonEncode({
            'total_assets': 5658.0,
            'cash': 2621.0,
            'buying_power': 2621.0,
            'market_value': 3037.0,
            'currency': 'USD',
            'realized_pl': 12.0,
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(
          jsonEncode({
            'positions': [
              {
                'code': 'US.NVDA',
                'symbol': 'NVDA',
                'quantity': 3.0,
                'can_sell_qty': 3.0,
                'cost_price': 100.0,
                'last_price': 110.0,
                'pl_val': 30.0,
                'pl_ratio': 0.10,
              },
            ],
          }),
          200,
        );
      }
      // sim endpoints (fallback) + trades
      if (req.url.path.endsWith('/sim/trades')) {
        return http.Response(jsonEncode({'trades': []}), 200);
      }
      return http.Response('{}', 200);
    }));
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));

    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, moomooSecret: secret), auth, repo));
    await tester.pumpAndSettle();

    // The Portfolio section relabels to the LIVE Moomoo view and the position
    // from the real account is shown.
    expect(find.text('Live Portfolio · Moomoo'), findsOneWidget);
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('holding_tile_NVDA_US')), 200,
        scrollable: list);
    expect(find.byKey(const Key('holding_tile_NVDA_US')), findsOneWidget);
    // Read-only: no simulated Buy/Sell buttons in the LIVE view.
    expect(find.byKey(const Key('holding_buy_NVDA_US')), findsNothing);
    expect(find.byKey(const Key('holding_sell_NVDA_US')), findsNothing);
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

  testWidgets('shows realized gain and total unrealized P/L from positions',
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
            'realized_pl': 123.45,
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

    // Realized gain comes straight from the broker account field.
    expect(find.text('Realized gain'), findsOneWidget);
    expect(find.textContaining('+\$123.45'), findsWidgets);
    // Net P/L = 35 - 20 = +15.00 over 800 cost basis = +1.88%.
    // 'Unrealized P/L' labels both the summary row and the sort chip; assert
    // the summary row exists by pairing the label with its value in one Row.
    expect(find.text('Unrealized P/L'), findsWidgets);
    expect(
      find.ancestor(
        of: find.text('Unrealized P/L'),
        matching: find.byType(Row),
      ),
      findsWidgets,
    );
    expect(find.textContaining('+\$15.00'), findsWidgets);
    // Per-position tiles render with avg cost.
    expect(find.byKey(const Key('moomoo_pos_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_AMD')), findsOneWidget);
  });

  testWidgets(
      'rebalance action for a held position is tappable and shows a sell '
      'slider; Sell opens the prefilled order ticket', (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/broker/moomoo/account')) {
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
      if (path.endsWith('/broker/moomoo/positions')) {
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
      if (path.contains('/broker/moomoo/rebalance')) {
        return http.Response(
          jsonEncode({
            'profile': 'Balanced',
            'portfolio_score': 80.0,
            'summary': 'Trim the overweight name.',
            'actions': [
              {
                'symbol': 'INTC',
                'market': 'US',
                'action': 'REDUCE',
                'reason': 'Overweight vs target.',
                'current_weight': 20.0,
                'target_weight': 10.0,
              },
            ],
          }),
          200,
        );
      }
      // Skip the other advisory cards.
      if (path.contains('/broker/moomoo/manager') ||
          path.contains('/broker/moomoo/health')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      // Preview returns within-cap so the ticket can proceed if used.
      if (path.endsWith('/broker/moomoo/order/preview')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'symbol': body['symbol'],
            'side': body['side'],
            'quantity': body['quantity'],
            'order_type': body['order_type'],
            'within_cap': true,
            'notional': 0.0,
          }),
          200,
        );
      }
      return http.Response('{}', 200);
    }));

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // The REDUCE row + Buy/Sell buttons render; the slider stays hidden
    // until the side is tapped (mirrors the Positions tile behaviour).
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_buy_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_sell_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_slider_INTC')), findsNothing);

    // Tapping the Sell button reveals its inline qty slider + confirm button.
    await tester.tap(find.byKey(const Key('moomoo_reb_sell_INTC')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_reb_slider_INTC')), findsOneWidget);
    expect(
        find.byKey(const Key('moomoo_pos_sell_range_INTC')), findsOneWidget);

    // Confirming Sell (default = full sellable qty) opens the order ticket
    // prefilled for INTC on the SELL side.
    await tester.tap(find.byKey(const Key('moomoo_pos_sell_confirm_INTC')));
    await tester.pumpAndSettle();
    expect(find.byType(MoomooOrderTicketPage), findsOneWidget);
    expect(find.text('SELL'), findsWidgets);
  });

  testWidgets('rebalance row with a pending order shows a Pending badge and '
      'can be filtered out', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/broker/moomoo/account')) {
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
      if (path.endsWith('/broker/moomoo/positions')) {
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
      // A still-working SELL order for INTC (e.g. submitted while closed).
      if (path.endsWith('/broker/moomoo/orders')) {
        return http.Response(
          jsonEncode({
            'orders': [
              {
                'order_id': 'OID-1',
                'code': 'US.INTC',
                'symbol': 'INTC',
                'side': 'SELL',
                'quantity': 10.0,
                'filled_quantity': 0.0,
                'price': 0.0,
                'status': 'SUBMITTED',
              },
            ],
          }),
          200,
        );
      }
      if (path.contains('/broker/moomoo/rebalance')) {
        return http.Response(
          jsonEncode({
            'profile': 'Balanced',
            'portfolio_score': 80.0,
            'summary': 'Trim the overweight name.',
            'actions': [
              {
                'symbol': 'INTC',
                'market': 'US',
                'action': 'REDUCE',
                'reason': 'Overweight vs target.',
                'current_weight': 20.0,
                'target_weight': 10.0,
              },
            ],
          }),
          200,
        );
      }
      if (path.contains('/broker/moomoo/manager') ||
          path.contains('/broker/moomoo/health')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // The REDUCE row shows a Pending badge; the matching (Sell) button is
    // disabled to prevent a double-submit.
    expect(find.byKey(const Key('moomoo_reb_pending_INTC')), findsOneWidget);
    final sellBtn = tester.widget<OutlinedButton>(
        find.byKey(const Key('moomoo_reb_sell_INTC')));
    expect(sellBtn.onPressed, isNull);

    // The filter hides the pending row entirely.
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsOneWidget);
    await tester.tap(find.byKey(const Key('moomoo_reb_hide_pending')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_reb_INTC')), findsNothing);
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

  testWidgets('positions sort chips reorder by P/L and weight, persist',
      (tester) async {
    // Tall viewport so both position tiles build and stay on-screen.
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithTwoPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    double topOf(Key k) => tester.getTopLeft(find.byKey(k)).dy;
    final intc = const Key('moomoo_pos_INTC');
    final amd = const Key('moomoo_pos_AMD');

    expect(find.byKey(intc), findsOneWidget);
    expect(find.byKey(amd), findsOneWidget);

    // First tap: sort by P/L high->low (desc): INTC (+35) above AMD (-20).
    await tester.tap(find.byKey(const Key('moomoo_sort_pl')));
    await tester.pumpAndSettle();
    expect(topOf(intc), lessThan(topOf(amd)));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tradewizz.moomoo.posSort'), 'pl');
    expect(prefs.getBool('tradewizz.moomoo.posSortDesc'), true);

    // Second tap on the active P/L chip: flip to low->high (asc): AMD above INTC.
    await tester.tap(find.byKey(const Key('moomoo_sort_pl')));
    await tester.pumpAndSettle();
    expect(topOf(amd), lessThan(topOf(intc)));
    expect(prefs.getString('tradewizz.moomoo.posSort'), 'pl');
    expect(prefs.getBool('tradewizz.moomoo.posSortDesc'), false);

    // Third tap on the active P/L chip: back to the broker's default order.
    await tester.tap(find.byKey(const Key('moomoo_sort_pl')));
    await tester.pumpAndSettle();
    expect(prefs.getString('tradewizz.moomoo.posSort'), 'default');
    expect(topOf(intc), lessThan(topOf(amd)));

    // Weight chip also cycles: high->low first (AMD 480 above INTC 335).
    await tester.tap(find.byKey(const Key('moomoo_sort_weight')));
    await tester.pumpAndSettle();
    expect(topOf(amd), lessThan(topOf(intc)));
    expect(prefs.getString('tradewizz.moomoo.posSort'), 'weight');
    expect(prefs.getBool('tradewizz.moomoo.posSortDesc'), true);

    // Then low->high (INTC above AMD).
    await tester.tap(find.byKey(const Key('moomoo_sort_weight')));
    await tester.pumpAndSettle();
    expect(topOf(intc), lessThan(topOf(amd)));
    expect(prefs.getBool('tradewizz.moomoo.posSortDesc'), false);

    // Then back to default.
    await tester.tap(find.byKey(const Key('moomoo_sort_weight')));
    await tester.pumpAndSettle();
    expect(prefs.getString('tradewizz.moomoo.posSort'), 'default');
    expect(topOf(intc), lessThan(topOf(amd)));
  });

  testWidgets('position tile shows invested equity (qty * avg cost) and now',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithTwoPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // INTC: 10 sh * $30 avg cost = $300 invested; now 10 * $33.50 = $335.
    expect(
      find.textContaining('Invested \$300.00 · now \$335.00'),
      findsOneWidget,
    );
    // AMD: 5 sh * $100 = $500 invested; now 5 * $96 = $480.
    expect(
      find.textContaining('Invested \$500.00 · now \$480.00'),
      findsOneWidget,
    );
  });

  testWidgets('position Sell expands an inline qty slider for held shares',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithTwoPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // Slider hidden until Sell is tapped.
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsNothing);

    await tester.tap(find.byKey(const Key('moomoo_pos_sell_INTC')));
    await tester.pumpAndSettle();

    // Inline SELL slider + confirm button now show; max reflects held (10).
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsOneWidget);
    expect(
        find.byKey(const Key('moomoo_pos_sell_range_INTC')), findsOneWidget);
    expect(
        find.byKey(const Key('moomoo_pos_sell_confirm_INTC')), findsOneWidget);
    expect(find.textContaining('max 10'), findsOneWidget);

    // Tapping Sell again collapses it.
    await tester.tap(find.byKey(const Key('moomoo_pos_sell_INTC')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsNothing);
  });

  testWidgets('position Buy expands its own inline qty slider; opening Buy '
      'collapses an open Sell slider', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWithTwoPositions();
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // Both Buy/Sell buttons render; neither slider is open initially.
    expect(find.byKey(const Key('moomoo_pos_buy_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_sell_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_buy_slider_INTC')), findsNothing);
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsNothing);

    // Open the Sell slider first.
    await tester.tap(find.byKey(const Key('moomoo_pos_sell_INTC')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsOneWidget);

    // Tapping Buy opens the BUY slider and collapses the open SELL slider.
    await tester.tap(find.byKey(const Key('moomoo_pos_buy_INTC')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_pos_buy_slider_INTC')), findsOneWidget);
    expect(
        find.byKey(const Key('moomoo_pos_buy_confirm_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_slider_INTC')), findsNothing);

    // Confirming Buy opens the order ticket prefilled on the BUY side.
    await tester.tap(find.byKey(const Key('moomoo_pos_buy_confirm_INTC')));
    await tester.pumpAndSettle();
    expect(find.byType(MoomooOrderTicketPage), findsOneWidget);
    expect(find.text('BUY'), findsWidgets);
  });

  testWidgets('sold-out positions (quantity 0) are hidden from the list',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    // INTC still held (10 sh); AMD fully sold (quantity 0) -> must not show.
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
                'quantity': 0.0,
                'can_sell_qty': 0.0,
                'cost_price': 100.0,
                'last_price': 96.0,
                'pl_val': 0.0,
                'pl_ratio': 0.0,
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

    // Only the held position renders; the sold-out one is filtered out.
    expect(find.byKey(const Key('moomoo_pos_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_pos_AMD')), findsNothing);
    // Count reflects only open positions (1, not 2).
    expect(find.textContaining('Positions (1)'), findsOneWidget);
  });

  testWidgets('Trim takes profit on every winner above the threshold',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final placed = <Map<String, dynamic>>[];
    // INTC +11.67% and MSFT +0.5% are winners; AMD -4% is a loser. With the
    // default threshold (>0%), Trim must SELL the two winners and never AMD.
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
                'code': 'US.MSFT',
                'symbol': 'MSFT',
                'quantity': 4.0,
                'can_sell_qty': 4.0,
                'cost_price': 100.0,
                'last_price': 100.5,
                'pl_val': 2.0,
                'pl_ratio': 0.005,
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
      if (req.url.path.endsWith('/broker/moomoo/order/place')) {
        placed.add(jsonDecode(req.body) as Map<String, dynamic>);
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'order_id': 'x',
            'symbol': b['symbol'],
            'side': b['side'],
            'quantity': b['quantity'],
            'status': 'SUBMITTED',
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
        MoomooLivePage(
          repository: repo,
          secretStore: store,
          liveBulkOrderGap: Duration.zero,
        ),
        auth,
        repo));
    await tester.pumpAndSettle();

    // Open the Trim sheet (default threshold 0% -> all three winners qualify
    // except the loser).
    await tester.tap(find.byKey(const Key('moomoo_trim_open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('moomoo_trim_slider')), findsOneWidget);

    // Total profit captured = INTC +35.0 + MSFT +2.0 = +$37.00.
    expect(
        find.byKey(const Key('moomoo_trim_total_gain')), findsOneWidget);
    expect(find.textContaining('Total profit +\$37.00'), findsOneWidget);

    // Execute -> LIVE confirm -> Sell now.
    await tester.tap(find.byKey(const Key('moomoo_trim_execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_trim_confirm')));
    await tester.pumpAndSettle();

    // Exactly the two winners were sold (full sellable qty, MARKET); not AMD.
    final sells = placed
        .where((b) => b['side'] == 'SELL')
        .map((b) => b['symbol'])
        .toSet();
    expect(sells, {'INTC', 'MSFT'});
    expect(sells.contains('AMD'), isFalse);
    final intc = placed.firstWhere((b) => b['symbol'] == 'INTC');
    expect(intc['order_type'], 'MARKET');
    expect(intc['quantity'], 10.0);
  });

  testWidgets('Trim never sells a momentum-strategy position', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final placed = <Map<String, dynamic>>[];
    // INTC and MSFT are both winners, but INTC is owned by the momentum
    // strategy (in /momentum/holdings) so Trim must protect it and sell only
    // MSFT.
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
                'code': 'US.MSFT',
                'symbol': 'MSFT',
                'quantity': 4.0,
                'can_sell_qty': 4.0,
                'cost_price': 100.0,
                'last_price': 100.5,
                'pl_val': 2.0,
                'pl_ratio': 0.005,
              },
            ],
          }),
          200,
        );
      }
      if (req.url.path.contains('/momentum/holdings')) {
        return http.Response(
          jsonEncode({
            'holdings': [
              {
                'symbol': 'INTC',
                'qty': 10.0,
                'cost_price': 30.0,
                'last_price': 33.5,
                'market_value': 335.0,
                'unrealized_pl': 35.0,
                'unrealized_pl_ratio': 0.1167,
                'in_top_n': true,
                'rank': 1,
              },
            ],
            'total_market_value': 335.0,
            'total_unrealized_pl': 35.0,
            'top_n': 10,
            'stale_symbols': [],
            'generated_at': '2026-07-06T00:00:00Z',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/order/place')) {
        placed.add(jsonDecode(req.body) as Map<String, dynamic>);
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'order_id': 'x',
            'symbol': b['symbol'],
            'side': b['side'],
            'quantity': b['quantity'],
            'status': 'SUBMITTED',
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
        MoomooLivePage(
          repository: repo,
          secretStore: store,
          liveBulkOrderGap: Duration.zero,
        ),
        auth,
        repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moomoo_trim_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_trim_execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_trim_confirm')));
    await tester.pumpAndSettle();

    // Only MSFT sold; INTC (momentum) protected.
    final sells = placed
        .where((b) => b['side'] == 'SELL')
        .map((b) => b['symbol'])
        .toSet();
    expect(sells, {'MSFT'});
    expect(sells.contains('INTC'), isFalse);
  });

  testWidgets('Trim supports a dollar (P/L \$) threshold mode', (tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = await _auth(kMoomooOwnerUid);
    final placed = <Map<String, dynamic>>[];
    // INTC +\$35 and MSFT +\$2 are winners by dollars; AMD -\$20 is a loser.
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
                'code': 'US.MSFT',
                'symbol': 'MSFT',
                'quantity': 4.0,
                'can_sell_qty': 4.0,
                'cost_price': 100.0,
                'last_price': 100.5,
                'pl_val': 2.0,
                'pl_ratio': 0.005,
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
      if (req.url.path.endsWith('/broker/moomoo/order/place')) {
        final b = jsonDecode(req.body) as Map<String, dynamic>;
        placed.add(b);
        return http.Response(
          jsonEncode({
            'order_id': 'x',
            'symbol': b['symbol'],
            'side': b['side'],
            'quantity': b['quantity'],
            'status': 'SUBMITTED',
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
        MoomooLivePage(
          repository: repo,
          secretStore: store,
          liveBulkOrderGap: Duration.zero,
        ),
        auth,
        repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('moomoo_trim_open')));
    await tester.pumpAndSettle();
    // Switch to dollar mode; both percent and dollar segments exist.
    expect(find.byKey(const Key('moomoo_trim_mode_pct')), findsOneWidget);
    await tester.tap(find.byKey(const Key('moomoo_trim_mode_usd')));
    await tester.pumpAndSettle();
    // The threshold label now reads in dollars (default \$0.00).
    expect(find.text('\$0.00'), findsWidgets);

    await tester.tap(find.byKey(const Key('moomoo_trim_execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_trim_confirm')));
    await tester.pumpAndSettle();

    final sells = placed
        .where((b) => b['side'] == 'SELL')
        .map((b) => b['symbol'])
        .toSet();
    // Both dollar-winners sell; the loser never does.
    expect(sells, {'INTC', 'MSFT'});
    expect(sells.contains('AMD'), isFalse);
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

    // Rebalance header mirrors the Account "Portfolio Rebalancing AI" template:
    // same title (no balance icon here) + Actions / HIGH priority / Est. +score
    // summary stats sourced from the SAME report fields.
    expect(find.text('Portfolio Rebalancing AI'), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_action_count')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_high_count')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_reb_score_improve')), findsOneWidget);
    // The Account balance icon must NOT appear on Moomoo Live.
    expect(find.byIcon(Icons.balance), findsNothing);

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

  testWidgets('portfolio growth chart renders from recorded equity history',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 5200.0,
            'cash': 4000.0,
            'buying_power': 4800.0,
            'market_value': 1200.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/account/history')) {
        return http.Response(
          jsonEncode({
            'points': [
              {'ts': 1700000000, 'equity': 5000.0},
              {'ts': 1700003600, 'equity': 5100.0},
              {'ts': 1700007200, 'equity': 5200.0},
            ],
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({'positions': []}), 200);
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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    // Growth card renders with the latest value and a +$200 / +4.00% delta.
    expect(find.byKey(const Key('moomoo_growth_card')), findsOneWidget);
    expect(find.text('Portfolio growth'), findsOneWidget);
    expect(find.textContaining('+\$200.00'), findsOneWidget);
    expect(find.textContaining('4.00%'), findsOneWidget);
  });

  testWidgets('position tile attaches a -1% / +3% SL-TP bracket',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final posted = <Map<String, dynamic>>[];
    // Positions fixture (INTC, cost 30) + record the bracket POST body.
    final repo = _repoWith(MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/broker/moomoo/account')) {
        return http.Response(jsonEncode({
          'total_assets': 5000.0, 'cash': 4000.0, 'buying_power': 4800.0,
          'market_value': 1000.0, 'currency': 'USD',
        }), 200);
      }
      if (p.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({
          'positions': [
            {
              'code': 'US.INTC', 'symbol': 'INTC', 'quantity': 10.0,
              'can_sell_qty': 10.0, 'cost_price': 30.0, 'last_price': 33.5,
              'pl_val': 35.0, 'pl_ratio': 0.1167,
            },
          ],
        }), 200);
      }
      if (p.contains('/broker/moomoo/manager') ||
          p.contains('/broker/moomoo/health') ||
          p.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      // No active brackets on load.
      if (p.endsWith('/broker/moomoo/brackets/check')) {
        return http.Response(jsonEncode({'brackets': []}), 200);
      }
      // Attach: echo a computed bracket back (cost 30 -> 29.7 / 30.9).
      if (p.endsWith('/broker/moomoo/brackets') && req.method == 'POST') {
        posted.add(jsonDecode(req.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({
          'symbol': 'INTC', 'quantity': 10.0, 'reference_price': 30.0,
          'stop_pct': -1.0, 'target_pct': 3.0,
          'stop_price': 29.7, 'target_price': 30.9, 'status': 'ACTIVE',
        }), 200);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // No bracket yet -> the Protect action is offered.
    final addKey = const Key('moomoo_sltp_add_INTC');
    expect(find.byKey(addKey), findsOneWidget);
    await tester.ensureVisible(find.byKey(addKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(addKey));
    await tester.pumpAndSettle();

    // Confirm the dialog -> POST /brackets fires with the cost as reference.
    await tester.tap(find.byKey(const Key('moomoo_sltp_confirm')));
    await tester.pumpAndSettle();
    expect(posted, hasLength(1));
    expect(posted.first['symbol'], 'INTC');
    expect(posted.first['reference_price'], 30.0);
    expect(posted.first['stop_pct'], -1.0);
    expect(posted.first['target_pct'], 3.0);

    // The tile now shows the active bracket (and a Remove action).
    expect(find.byKey(const Key('moomoo_sltp_active_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_sltp_cancel_INTC')), findsOneWidget);
  });

  testWidgets('Momentum Research entry lives on the Moomoo Live page',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        return http.Response(
          jsonEncode({
            'total_assets': 1000.0, 'cash': 1000.0, 'buying_power': 1000.0,
            'market_value': 0.0, 'currency': 'USD', 'realized_pl': 0.0,
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({'positions': []}), 200);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // Moved here from Explore: the momentum research entry is present.
    expect(find.byKey(const Key('moomoo_momentum_entry')), findsOneWidget);
    expect(find.text('Momentum Research'), findsOneWidget);
  });

  testWidgets('an active bracket shows on load and can be removed',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    var cancelled = false;
    final repo = _repoWith(MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/broker/moomoo/account')) {
        return http.Response(jsonEncode({
          'total_assets': 5000.0, 'cash': 4000.0, 'buying_power': 4800.0,
          'market_value': 1000.0, 'currency': 'USD',
        }), 200);
      }
      if (p.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({
          'positions': [
            {
              'code': 'US.INTC', 'symbol': 'INTC', 'quantity': 10.0,
              'can_sell_qty': 10.0, 'cost_price': 30.0, 'last_price': 33.5,
              'pl_val': 35.0, 'pl_ratio': 0.1167,
            },
          ],
        }), 200);
      }
      if (p.contains('/broker/moomoo/manager') ||
          p.contains('/broker/moomoo/health') ||
          p.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      // An ACTIVE bracket is returned on the load-time check.
      if (p.endsWith('/broker/moomoo/brackets/check')) {
        return http.Response(jsonEncode({'brackets': [
          {
            'symbol': 'INTC', 'quantity': 10.0, 'reference_price': 30.0,
            'stop_pct': -1.0, 'target_pct': 3.0,
            'stop_price': 29.7, 'target_price': 30.9, 'status': 'ACTIVE',
          },
        ]}), 200);
      }
      if (p.endsWith('/broker/moomoo/brackets/INTC') &&
          req.method == 'DELETE') {
        cancelled = true;
        return http.Response(jsonEncode({
          'symbol': 'INTC', 'quantity': 10.0, 'reference_price': 30.0,
          'stop_pct': -1.0, 'target_pct': 3.0,
          'stop_price': 29.7, 'target_price': 30.9, 'status': 'CANCELLED',
        }), 200);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // The active bracket is shown (not the Protect action).
    expect(find.byKey(const Key('moomoo_sltp_active_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_sltp_add_INTC')), findsNothing);

    // Remove it (ensure the row is on-screen first).
    await tester.ensureVisible(
        find.byKey(const Key('moomoo_sltp_cancel_INTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_sltp_cancel_INTC')));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(find.byKey(const Key('moomoo_sltp_add_INTC')), findsOneWidget);
  });

  testWidgets('Protect all attaches a bracket to every unprotected position',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final posted = <Map<String, dynamic>>[];
    final repo = _repoWith(MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/broker/moomoo/account')) {
        return http.Response(jsonEncode({
          'total_assets': 5000.0, 'cash': 4000.0, 'buying_power': 4800.0,
          'market_value': 1000.0, 'currency': 'USD',
        }), 200);
      }
      if (p.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({
          'positions': [
            {
              'code': 'US.INTC', 'symbol': 'INTC', 'quantity': 10.0,
              'can_sell_qty': 10.0, 'cost_price': 30.0, 'last_price': 33.5,
              'pl_val': 35.0, 'pl_ratio': 0.1167,
            },
            {
              'code': 'US.AMD', 'symbol': 'AMD', 'quantity': 5.0,
              'can_sell_qty': 5.0, 'cost_price': 100.0, 'last_price': 96.0,
              'pl_val': -20.0, 'pl_ratio': -0.04,
            },
          ],
        }), 200);
      }
      if (p.contains('/broker/moomoo/manager') ||
          p.contains('/broker/moomoo/health') ||
          p.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      // Nothing protected at load time.
      if (p.endsWith('/broker/moomoo/brackets/check')) {
        return http.Response(jsonEncode({'brackets': []}), 200);
      }
      // Attach: echo back a bracket computed from the posted reference.
      if (p.endsWith('/broker/moomoo/brackets') && req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posted.add(body);
        final ref = (body['reference_price'] as num).toDouble();
        return http.Response(jsonEncode({
          'symbol': body['symbol'], 'quantity': body['quantity'],
          'reference_price': ref, 'stop_pct': -1.0, 'target_pct': 3.0,
          'stop_price': ref * 0.99, 'target_price': ref * 1.03,
          'status': 'ACTIVE',
        }), 200);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));

    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // The Protect-all toggle is offered (off, since nothing is protected).
    expect(find.byKey(const Key('moomoo_sltp_protect_all')), findsOneWidget);
    await tester.tap(find.byKey(const Key('moomoo_sltp_protect_all')));
    await tester.pumpAndSettle();

    // Confirm the batch -> a POST fires for each position.
    await tester
        .tap(find.byKey(const Key('moomoo_sltp_protect_all_confirm')));
    await tester.pumpAndSettle();

    final symbols = posted.map((b) => b['symbol']).toSet();
    expect(posted, hasLength(2));
    expect(symbols, {'INTC', 'AMD'});
    // Each used its own cost as the reference price.
    final intc = posted.firstWhere((b) => b['symbol'] == 'INTC');
    final amd = posted.firstWhere((b) => b['symbol'] == 'AMD');
    expect(intc['reference_price'], 30.0);
    expect(amd['reference_price'], 100.0);

    // Both positions now show an active bracket.
    expect(find.byKey(const Key('moomoo_sltp_active_INTC')), findsOneWidget);
    expect(find.byKey(const Key('moomoo_sltp_active_AMD')), findsOneWidget);
  });

  testWidgets('a custom SL/TP plan is used and persisted when protecting',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final posted = <Map<String, dynamic>>[];
    final repo = _repoWith(MockClient((req) async {
      final p = req.url.path;
      if (p.endsWith('/broker/moomoo/account')) {
        return http.Response(jsonEncode({
          'total_assets': 5000.0, 'cash': 4000.0, 'buying_power': 4800.0,
          'market_value': 1000.0, 'currency': 'USD',
        }), 200);
      }
      if (p.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({
          'positions': [
            {
              'code': 'US.INTC', 'symbol': 'INTC', 'quantity': 10.0,
              'can_sell_qty': 10.0, 'cost_price': 30.0, 'last_price': 33.5,
              'pl_val': 35.0, 'pl_ratio': 0.1167,
            },
          ],
        }), 200);
      }
      if (p.contains('/broker/moomoo/manager') ||
          p.contains('/broker/moomoo/health') ||
          p.contains('/broker/moomoo/rebalance')) {
        return http.Response('{"detail":"nope"}', 404);
      }
      if (p.endsWith('/broker/moomoo/brackets/check')) {
        return http.Response(jsonEncode({'brackets': []}), 200);
      }
      if (p.endsWith('/broker/moomoo/brackets') && req.method == 'POST') {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        posted.add(body);
        final ref = (body['reference_price'] as num).toDouble();
        final sp = (body['stop_pct'] as num).toDouble();
        final tp = (body['target_pct'] as num).toDouble();
        return http.Response(jsonEncode({
          'symbol': body['symbol'], 'quantity': body['quantity'],
          'reference_price': ref, 'stop_pct': sp, 'target_pct': tp,
          'stop_price': ref * (1 + sp / 100),
          'target_price': ref * (1 + tp / 100), 'status': 'ACTIVE',
        }), 200);
      }
      return http.Response('{}', 200);
    }));
    final store = MoomooSecretStore(persistence: _MemSecret('topsecret'));

    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // Default plan label is shown.
    expect(find.byKey(const Key('moomoo_sltp_plan_label')), findsOneWidget);

    // Open the plan editor and set SL 2 / TP 3.2.
    await tester.tap(find.byKey(const Key('moomoo_sltp_settings_open')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moomoo_sltp_stop_field')), '2');
    await tester.enterText(
        find.byKey(const Key('moomoo_sltp_target_field')), '3.2');
    await tester.tap(find.byKey(const Key('moomoo_sltp_settings_save')));
    await tester.pumpAndSettle();

    // Attach a bracket -> the POST carries the custom percentages.
    await tester.tap(find.byKey(const Key('moomoo_sltp_add_INTC')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('moomoo_sltp_confirm')));
    await tester.pumpAndSettle();

    expect(posted, hasLength(1));
    expect(posted.first['stop_pct'], -2.0);
    expect(posted.first['target_pct'], 3.2);

    // The plan pill reflects the saved plan, and the value was written to
    // SharedPreferences so it survives relaunch.
    final label = tester.widget<Text>(
        find.byKey(const Key('moomoo_sltp_plan_label')));
    expect(label.data, '-2% / +3.20%');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('tradewizz.moomoo.sltpStopPct'), -2.0);
    expect(prefs.getDouble('tradewizz.moomoo.sltpTargetPct'), 3.2);
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
