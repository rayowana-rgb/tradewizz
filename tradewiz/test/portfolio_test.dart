import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/portfolio_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

Map<String, dynamic> _portfolioJson({
  bool withPositions = true,
  bool multiBroker = false,
  bool ibkrError = false,
}) =>
    {
      'summary': {
        'total_equity': multiBroker ? 225000.0 : 150000.0,
        'cash': 100000.0,
        'buying_power': 200000.0,
        'market_value': 41260.0,
        'floating_pnl': 3260.0,
        'realized_pnl': 0.0,
      },
      'positions': withPositions
          ? [
              {
                'symbol': 'HK.00700',
                'market': 'HKEX',
                'broker': 'MOOMOO',
                'quantity': 100.0,
                'average_cost': 380.0,
                'current_price': 412.6,
                'market_value': 41260.0,
                'unrealized_pnl': 3260.0,
              },
              if (multiBroker)
                {
                  'symbol': 'AAPL',
                  'market': 'HKEX',
                  'broker': 'IBKR',
                  'quantity': 10.0,
                  'average_cost': 180.0,
                  'current_price': 0.0,
                  'market_value': 1800.0,
                  'unrealized_pnl': 0.0,
                },
            ]
          : <Map<String, dynamic>>[],
      'brokers': withPositions
          ? (multiBroker ? ['MOOMOO', 'IBKR'] : ['MOOMOO'])
          : <String>[],
      'errors': ibkrError
          ? [
              {
                'broker': 'IBKR',
                'message': 'IBKR is not reachable; its data is excluded.',
              }
            ]
          : <Map<String, dynamic>>[],
    };

StockRepository _repo({
  bool withPositions = true,
  bool multiBroker = false,
  bool ibkrError = false,
}) =>
    StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/portfolio')) {
            return http.Response(
              jsonEncode(_portfolioJson(
                withPositions: withPositions,
                multiBroker: multiBroker,
                ibkrError: ibkrError,
              )),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('not found', 404);
        }),
      ),
    );

Widget _wrap(StockRepository repo, {bool loggedIn = true}) {
  final auth = AuthStore();
  if (loggedIn) {
    auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  }
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth,
      child: MaterialApp(
        home: Scaffold(body: PortfolioPage(repository: repo)),
      ),
    ),
  );
}

void main() {
  testWidgets('logged out: prompts to sign in', (tester) async {
    await tester.pumpWidget(_wrap(_repo(), loggedIn: false));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sign in'), findsOneWidget);
    expect(find.text('Summary'), findsNothing);
  });

  testWidgets('Summary tab shows equity, cash and P/L', (tester) async {
    await tester.pumpWidget(_wrap(_repo()));
    await tester.pumpAndSettle();

    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Orders'), findsOneWidget);

    expect(find.byKey(const Key('total_equity')), findsOneWidget);
    expect(find.text('150000.00'), findsOneWidget); // total equity
    expect(find.byKey(const Key('cash')), findsOneWidget);
    expect(find.text('100000.00'), findsOneWidget); // cash
    expect(find.byKey(const Key('floating_pnl')), findsOneWidget);
    expect(find.byKey(const Key('realized_pnl')), findsOneWidget);
    expect(find.textContaining('Aggregated from: MOOMOO'), findsOneWidget);
  });

  testWidgets('Positions tab lists aggregated positions', (tester) async {
    await tester.pumpWidget(_wrap(_repo()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Positions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HK.00700'), findsOneWidget);
    expect(find.textContaining('MOOMOO'), findsWidgets);
  });

  testWidgets('Positions tab shows empty state when no positions',
      (tester) async {
    await tester.pumpWidget(_wrap(_repo(withPositions: false)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Positions'));
    await tester.pumpAndSettle();
    expect(find.text('No open positions.'), findsOneWidget);
  });

  testWidgets('Portfolio shows multiple brokers (Moomoo + IBKR)',
      (tester) async {
    await tester.pumpWidget(_wrap(_repo(multiBroker: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Aggregated from: MOOMOO, IBKR'),
        findsOneWidget);
    expect(find.text('225000.00'), findsOneWidget); // combined equity

    await tester.tap(find.text('Positions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HK.00700'), findsOneWidget);
    expect(find.textContaining('AAPL'), findsOneWidget);
  });

  testWidgets('Portfolio shows IBKR error when gateway is down',
      (tester) async {
    await tester.pumpWidget(_wrap(_repo(ibkrError: true)));
    await tester.pumpAndSettle();
    // Moomoo equity still shown.
    expect(find.text('150000.00'), findsOneWidget);
    // IBKR error is at the bottom of the Summary list; scroll it into view.
    await tester.dragUntilVisible(
      find.byKey(const Key('portfolio_error_IBKR')),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('portfolio_error_IBKR')), findsOneWidget);
    expect(find.textContaining('IBKR is not reachable'), findsOneWidget);
  });
}
