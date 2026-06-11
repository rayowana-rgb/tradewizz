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

Map<String, dynamic> _performanceJson({
  bool multiBroker = false,
  bool hasHistory = false,
}) =>
    {
      'total_equity': multiBroker ? 225000.0 : 150000.0,
      'cash': 100000.0,
      'market_value': 41260.0,
      'floating_pnl': 3260.0,
      'realized_pnl': 0.0,
      'total_pnl': 3260.0,
      'daily_pnl': hasHistory ? 5000.0 : 0.0,
      'daily_pnl_percent': hasHistory ? 3.45 : 0.0,
      'equity_curve': hasHistory
          ? [
              {'timestamp': '2026-06-06T12:00:00Z', 'total_equity': 145000.0},
              {'timestamp': '2026-06-07T12:00:00Z', 'total_equity': 150000.0},
            ]
          : <Map<String, dynamic>>[],
      'broker_breakdown': [
        {
          'broker': 'MOOMOO',
          'equity': 41260.0,
          'cash': 0.0,
          'market_value': 41260.0,
          'floating_pnl': 3260.0,
        },
        if (multiBroker)
          {
            'broker': 'IBKR',
            'equity': 1800.0,
            'cash': 0.0,
            'market_value': 1800.0,
            'floating_pnl': 0.0,
          },
      ],
      'asset_breakdown': [
        {'asset': 'Cash', 'market_value': 100000.0, 'floating_pnl': 0.0},
        {'asset': 'HKEX', 'market_value': 41260.0, 'floating_pnl': 3260.0},
      ],
      'top_winners': [
        {
          'symbol': 'HK.00700',
          'broker': 'MOOMOO',
          'unrealized_pnl': 3260.0,
          'unrealized_pnl_percent': 8.58,
        }
      ],
      'top_losers': <Map<String, dynamic>>[],
      'notes': hasHistory
          ? ['Realized P/L not available for this broker yet.']
          : [
              'Realized P/L not available for this broker yet.',
              'No performance history yet.',
            ],
      'errors': <Map<String, dynamic>>[],
    };

StockRepository _repo({
  bool withPositions = true,
  bool multiBroker = false,
  bool ibkrError = false,
  bool hasHistory = false,
}) =>
    StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/portfolio/performance')) {
            return http.Response(
              jsonEncode(_performanceJson(
                multiBroker: multiBroker, hasHistory: hasHistory)),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
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
    // Aggregation note sits below the fold; scroll it into view.
    await tester.dragUntilVisible(
      find.textContaining('Aggregated from: MOOMOO'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
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
    await tester.dragUntilVisible(
      find.textContaining('Aggregated from: MOOMOO, IBKR'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
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

  // --- Performance tab ------------------------------------------------------

  Future<void> openPerformance(WidgetTester tester) async {
    await tester.tap(find.text('Performance'));
    await tester.pumpAndSettle();
  }

  testWidgets('Performance tab renders P/L metrics', (tester) async {
    await tester.pumpWidget(_wrap(_repo(multiBroker: true)));
    await tester.pumpAndSettle();
    await openPerformance(tester);

    expect(find.byKey(const Key('perf_total_pnl')), findsOneWidget);
    expect(find.byKey(const Key('perf_daily_pnl')), findsOneWidget);
    expect(find.byKey(const Key('perf_floating_pnl')), findsOneWidget);
    expect(find.byKey(const Key('perf_realized_pnl')), findsOneWidget);
  });

  testWidgets('Performance tab shows broker breakdown', (tester) async {
    await tester.pumpWidget(_wrap(_repo(multiBroker: true)));
    await tester.pumpAndSettle();
    await openPerformance(tester);
    expect(find.byKey(const Key('broker_bd_MOOMOO')), findsOneWidget);
    expect(find.byKey(const Key('broker_bd_IBKR')), findsOneWidget);
  });

  testWidgets('Performance tab shows top winners and losers', (tester) async {
    await tester.pumpWidget(_wrap(_repo()));
    await tester.pumpAndSettle();
    await openPerformance(tester);
    expect(find.text('Top Winners'), findsOneWidget);
    expect(find.text('Top Losers'), findsOneWidget);
    expect(find.textContaining('HK.00700'), findsOneWidget);
    expect(find.text('No losers yet.'), findsOneWidget);
  });

  testWidgets('Performance tab: no history state', (tester) async {
    await tester.pumpWidget(_wrap(_repo(hasHistory: false)));
    await tester.pumpAndSettle();
    await openPerformance(tester);
    // Scroll to the equity-curve section.
    await tester.dragUntilVisible(
      find.text('No performance history yet.'),
      find.byType(ListView).first,
      const Offset(0, -250),
    );
    expect(find.text('No performance history yet.'), findsOneWidget);
  });

  testWidgets('Performance tab: realized P/L note shown', (tester) async {
    await tester.pumpWidget(_wrap(_repo()));
    await tester.pumpAndSettle();
    await openPerformance(tester);
    expect(find.byKey(const Key('realized_note')), findsOneWidget);
  });
}
