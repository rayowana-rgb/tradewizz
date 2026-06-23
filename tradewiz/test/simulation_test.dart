import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/broker.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/pages/order_ticket_page.dart';
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

/// Simulation backend whose portfolio carries one PENDING order. A cancel POST
/// flips [cancelled] and the next portfolio fetch returns an empty pending
/// list (mirroring the real backend releasing the reserve).
StockRepository _simRepoWithPending(List<String> cancelLog) {
  Map<String, dynamic> account(int pending) => {
        'cash': 1000000.0,
        'equity': 1000000.0,
        'buying_power': pending > 0 ? 999184.56 : 1000000.0,
        'market_value': 0.0,
        'unrealized_pnl': 0.0,
        'realized_pnl': 0.0,
        'currency': 'USD',
        'simulated': true,
        'disclaimer':
            'This is a simulated portfolio. No real broker order is sent.',
        'reserved_cash': pending > 0 ? 815.44 : 0.0,
        'pending_orders': pending,
      };
    final pendingOrder = {
      'order_id': 'SIM-PEND01',
      'symbol': 'ARM',
      'market': 'US',
      'side': 'BUY',
      'quantity': 2.0,
      'order_type': 'MARKET',
      'limit_price': null,
      'reserved_cash': 815.44,
      'placed_trading_date': '2026-06-22',
      'status': 'PENDING_SIMULATED',
      'placed_at': '2026-06-23T02:00:00Z',
    };
  final fake = MockClient((req) async {
    final path = req.url.path;
    final cancelled = cancelLog.isNotEmpty;
    if (path.contains('/sim/order/cancel/')) {
      cancelLog.add(path.split('/').last);
      return http.Response(
        jsonEncode({
          'order_id': 'SIM-PEND01',
          'status': 'CANCELLED_SIMULATED',
          'cash_after': 1000000.0,
          'simulated': true,
          'message': 'Pending simulated order cancelled.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': account(cancelled ? 0 : 1),
          'positions': const [],
          'pending': cancelled ? const [] : [pendingOrder],
          'simulated': true,
          'disclaimer':
              'This is a simulated portfolio. No real broker order is sent.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/trades')) {
      return http.Response(jsonEncode({'trades': const [], 'simulated': true}),
          200, headers: {'content-type': 'application/json'});
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

    // Holdings card with the AAPL position (scroll it into the lazy list).
    await tester.scrollUntilVisible(
      find.byKey(const Key('account_holdings_card')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('account_holdings_card')), findsOneWidget);
    expect(find.text('AAPL · US'), findsWidgets);
    // Trade history card with the BUY trade. Use a small scroll delta so the
    // short trades card (just below holdings) is not overshot.
    await tester.scrollUntilVisible(
      find.byKey(const Key('account_trades_card')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('BUY 10 AAPL'), findsOneWidget);
  });

  testWidgets('Holdings and Trade History can be collapsed and expanded',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    // Both sections start expanded -> their cards are present.
    await tester.scrollUntilVisible(
      find.byKey(const Key('account_holdings_header')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('account_holdings_card')), findsOneWidget);

    // Tapping the Holdings header collapses it -> card is removed.
    await tester.tap(find.byKey(const Key('account_holdings_header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_holdings_card')), findsNothing);
    // The header itself stays so the user can expand it again.
    expect(find.byKey(const Key('account_holdings_header')), findsOneWidget);

    // Tapping again expands it back.
    await tester.tap(find.byKey(const Key('account_holdings_header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_holdings_card')), findsOneWidget);

    // Same for Trade History.
    await tester.scrollUntilVisible(
      find.byKey(const Key('account_trades_header')),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('account_trades_header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_trades_card')), findsNothing);
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

  testWidgets('Tapping a holding opens the analysis detail page',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('holding_tile_AAPL_US')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('holding_tile_AAPL_US')));
    await tester.pumpAndSettle();

    // The shared analysis detail page is pushed for AAPL / US.
    expect(find.byType(AnalysisDetailPage), findsOneWidget);
    expect(find.text('AAPL · US'), findsWidgets);
  });

  testWidgets('Holding Buy opens the simulated order ticket (BUY)',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('holding_buy_AAPL_US')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('holding_buy_AAPL_US')));
    await tester.pumpAndSettle();

    final ticket =
        tester.widget<OrderTicketPage>(find.byType(OrderTicketPage));
    expect(ticket.symbol, 'AAPL');
    expect(ticket.side, OrderSide.buy);
    expect(ticket.maxQuantity, isNull); // buy is not capped
    expect(find.byKey(const Key('sim_warning_banner')), findsOneWidget);
  });

  testWidgets('Holding Sell opens the order ticket prefilled + capped (SELL)',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('holding_sell_AAPL_US')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('holding_sell_AAPL_US')));
    await tester.pumpAndSettle();

    final ticket =
        tester.widget<OrderTicketPage>(find.byType(OrderTicketPage));
    expect(ticket.symbol, 'AAPL');
    expect(ticket.side, OrderSide.sell);
    // Sell prefills + caps at the held quantity (10).
    expect(ticket.initialQuantity, 10.0);
    expect(ticket.maxQuantity, 10.0);
    expect(find.byKey(const Key('sim_warning_banner')), findsOneWidget);
    // Quantity field is prefilled with the full holding.
    final qty = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('qty_field')),
        matching: find.byType(TextField),
      ),
    );
    expect(qty.controller!.text, '10');
  });

  testWidgets('Pending orders section renders queued order details',
      (tester) async {
    final repo = _simRepoWithPending([]);
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('account_pending_card')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('account_pending_header')), findsOneWidget);
    expect(find.byKey(const Key('pending_tile_SIM-PEND01')), findsOneWidget);
    expect(find.text('BUY 2 ARM \u00b7 US'), findsOneWidget);
    expect(find.byKey(const Key('pending_cancel_SIM-PEND01')), findsOneWidget);
  });

  testWidgets('No pending section when there are no pending orders',
      (tester) async {
    final repo = _simRepo();
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_pending_header')), findsNothing);
    expect(find.byKey(const Key('account_pending_card')), findsNothing);
  });

  testWidgets('Cancel pending order calls the cancel endpoint + refreshes',
      (tester) async {
    final cancelLog = <String>[];
    final repo = _simRepoWithPending(cancelLog);
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('pending_cancel_SIM-PEND01')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('pending_cancel_SIM-PEND01')));
    await tester.pumpAndSettle();

    // Confirm dialog -> tap the destructive action.
    expect(find.text('Cancel pending order?'), findsOneWidget);
    await tester.tap(find.text('Cancel order'));
    await tester.pumpAndSettle();

    // The cancel endpoint was hit with the right order id, and after the
    // refresh the pending section is gone.
    expect(cancelLog, contains('SIM-PEND01'));
    expect(find.byKey(const Key('account_pending_header')), findsNothing);
  });
}
