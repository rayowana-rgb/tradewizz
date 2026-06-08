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
import 'package:tradewiz/services/repository_scope.dart';

/// Simulation backend serving a portfolio with one open position + one trade.
StockRepository _simRepo() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': {
            'cash': 998000.0,
            'equity': 1000200.0,
            'buying_power': 998000.0,
            'market_value': 2200.0,
            'unrealized_pnl': 200.0,
            'realized_pnl': 0.0,
            'currency': 'USD',
            'simulated': true,
            'disclaimer':
                'This is a simulated portfolio. No real broker order is sent.',
          },
          'positions': [
            {
              'symbol': 'AAPL',
              'market': 'US',
              'quantity': 10.0,
              'average_cost': 200.0,
              'last_price': 220.0,
              'market_value': 2200.0,
              'unrealized_pnl': 200.0,
              'realized_pnl': 0.0,
            }
          ],
          'simulated': true,
          'disclaimer':
              'This is a simulated portfolio. No real broker order is sent.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/trades')) {
      return http.Response(
        jsonEncode({
          'trades': [
            {
              'order_id': 'SIM-1',
              'symbol': 'AAPL',
              'market': 'US',
              'side': 'BUY',
              'quantity': 10.0,
              'price': 200.0,
              'value': 2000.0,
              'realized_pnl': 0.0,
              'created_at': '2026-06-09T00:00:00Z',
            }
          ],
          'simulated': true,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/auth/logout')) {
      return http.Response(jsonEncode({'success': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
}

AuthStore _loggedIn() {
  final s = AuthStore();
  s.setSession(
    'JWT',
    const UserProfile(
        id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''),
  );
  return s;
}

Widget _wrap(Widget child, StockRepository repo) => RepositoryScope(
      repository: repo,
      child: AuthScope(
        store: _loggedIn(),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    );

void main() {
  testWidgets('Account page shows the simulation disclaimer', (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account_sim_disclaimer')), findsOneWidget);
    expect(
      find.textContaining('No real broker order is sent'),
      findsWidgets,
    );
  });

  testWidgets('Account page lists simulated positions and trades',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    // Holdings card with the AAPL position.
    expect(find.byKey(const Key('account_holdings_card')), findsOneWidget);
    expect(find.text('AAPL · US'), findsWidgets);
    // Trade history card with the BUY trade.
    await tester.scrollUntilVisible(
      find.byKey(const Key('account_trades_card')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('BUY 10 AAPL'), findsOneWidget);
  });

  testWidgets('Buying power + simulated cash are shown (no broker UI)',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account_buying_power')), findsOneWidget);
    expect(find.byKey(const Key('account_cash')), findsOneWidget);
    expect(find.byKey(const Key('account_realized_pnl')), findsOneWidget);
    // No broker connection wording anywhere.
    expect(find.textContaining('Broker'), findsNothing);
    expect(find.textContaining('IBKR'), findsNothing);
    expect(find.textContaining('Moomoo'), findsNothing);
  });
}
