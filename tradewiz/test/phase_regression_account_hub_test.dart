import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/repository_scope.dart';

StockRepository _repo() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': {
            'cash': 90000.0,
            'equity': 150000.0,
            'buying_power': 90000.0,
            'market_value': 60000.0,
            'unrealized_pnl': 1200.0,
            'realized_pnl': 0.0,
            'currency': 'USD',
            'simulated': true,
            'disclaimer': 'Simulated.',
          },
          'positions': [
            {
              'symbol': 'AAPL',
              'market': 'US',
              'quantity': 10,
              'average_cost': 100.0,
              'last_price': 120.0,
              'market_value': 1200.0,
              'unrealized_pnl': 200.0,
            }
          ],
          'simulated': true,
          'disclaimer': 'Simulated.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/trades')) {
      return http.Response(
          jsonEncode({'trades': [], 'simulated': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.contains('/portfolio/health')) {
      return http.Response(
        jsonEncode({
          'health_score': 78.0,
          'rating': 'Healthy',
          'components': {},
          'warnings': ['One position is concentrated.'],
          'strengths': ['Diversified across sectors.'],
          'exit_warnings': [],
          'positions': [],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Manager / rebalance / anything else: empty-ish 200 so cards don't error.
    return http.Response(jsonEncode({}), 200,
        headers: {'content-type': 'application/json'});
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
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

void main() {
  testWidgets('Account is the portfolio hub (summary, holdings, health, '
      'manager, rebalance, journal, brokers)', (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
        id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _repo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;

    // Simulation summary + holdings (with Buy/Sell) are present.
    expect(find.byKey(const Key('account_portfolio_card')), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('account_health_section')), 300,
        scrollable: list);
    expect(find.byKey(const Key('account_health_section')), findsOneWidget);
    expect(find.byKey(const Key('account_health_card')), findsOneWidget);
    expect(find.byKey(const Key('account_health_score')), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('account_manager_section')), 300,
        scrollable: list);
    expect(find.byKey(const Key('account_manager_section')), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('account_journal_link')), 300,
        scrollable: list);
    expect(find.byKey(const Key('account_journal_link')), findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('account_brokers_portfolio_link')), 300,
        scrollable: list);
    expect(find.byKey(const Key('account_brokers_portfolio_link')),
        findsOneWidget);

    await tester.scrollUntilVisible(
        find.byKey(const Key('reset_simulation_button')), 300,
        scrollable: list);
    expect(find.byKey(const Key('reset_simulation_button')), findsOneWidget);
  });

  testWidgets('Buy/Sell from an Account holding opens the order ticket',
      (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
        id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _repo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('holding_buy_AAPL_US')), 300,
        scrollable: list);
    expect(find.byKey(const Key('holding_buy_AAPL_US')), findsOneWidget);
    expect(find.byKey(const Key('holding_sell_AAPL_US')), findsOneWidget);
  });
}
