import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/pages/order_ticket_page.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/watchlist_store.dart';

import 'helpers.dart';

void main() {
  testWidgets('AI Analysis form produces a placeholder result', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(market: Market.idx, repository: offlineRepository()),
      ),
    );

    // Enter a symbol and submit.
    await tester.enterText(find.byType(TextFormField), 'BBCA');
    await tester.tap(find.widgetWithText(FilledButton, 'Analyze'));
    await tester.pump(); // start loading

    // Let the mocked latency resolve.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // A signal badge should be present.
    expect(find.textContaining('Score'), findsOneWidget);

    // Weekly forecast card is further down the list; scroll it into view.
    await tester.scrollUntilVisible(
      find.textContaining('Weekly forecast'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Weekly forecast'), findsOneWidget);
  });

  testWidgets('autoRun analyzes the prefilled symbol on open', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(
          market: Market.hkex,
          initialSymbol: '0700',
          autoRun: true,
          repository: offlineRepository(),
        ),
      ),
    );

    await tester.pump(); // post-frame autoRun fires
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Result rendered without any manual input.
    expect(find.textContaining('Score'), findsOneWidget);
    expect(find.text('0700'), findsWidgets);
  });

  testWidgets('Save to Watchlist adds the analyzed symbol to the store',
      (tester) async {
    final store = WatchlistStore(seed: false);
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(
          market: Market.idx,
          initialSymbol: 'BBCA',
          autoRun: true,
          repository: offlineRepository(),
        ),
        store: store,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(store.contains('BBCA', Market.idx), isFalse);

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Save to Watchlist'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Save to Watchlist'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save to Watchlist'));
    await tester.pumpAndSettle();

    expect(store.contains('BBCA', Market.idx), isTrue);
    expect(find.text('Saved to Watchlist'), findsOneWidget);
  });

  testWidgets('shows recommendation, profit probability and buy reasons',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(
          market: Market.idx,
          initialSymbol: 'BBCA',
          autoRun: true,
          repository: offlineRepository(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Recommendation'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Recommendation'), findsOneWidget);
    expect(find.textContaining('Profit probability'), findsOneWidget);
    expect(find.text('Reasons'), findsOneWidget);
  });

  testWidgets('shows support/resistance and trailing stop', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(
          market: Market.idx,
          initialSymbol: 'BBCA',
          autoRun: true,
          repository: offlineRepository(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Support / Resistance'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Support / Resistance'), findsOneWidget);
    expect(find.text('Imm. support'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Suggested trailing stop'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Suggested trailing stop'), findsOneWidget);
  });

  testWidgets(
      'HKEX analysis -> Buy opens an OrderTicket that preserves market=HKEX',
      (tester) async {
    final auth = AuthStore();
    auth.setSession(
      'JWT',
      const UserProfile(
        id: 1,
        email: 'x@x.com',
        createdAt: '2026-06-08T00:00:00Z',
        updatedAt: '2026-06-08T00:00:00Z',
      ),
    );
    await tester.pumpWidget(
      AuthScope(
        store: auth,
        child: wrapApp(
          AiAnalysisPage(
            market: Market.hkex,
            initialSymbol: '03417',
            autoRun: true,
            repository: offlineRepository(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Buy is offered for HKEX; tap it to open the order ticket.
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Buy'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Buy'));
    await tester.pumpAndSettle();

    // The pushed OrderTicketPage carries HKEX, not the IDX fallback.
    final ticket = tester.widget<OrderTicketPage>(
      find.byType(OrderTicketPage),
    );
    expect(ticket.market, Market.hkex);
    expect(ticket.symbol, '03417');
    expect(find.textContaining('HKEX'), findsWidgets);
  });

  testWidgets('shows the Backtest section with stats', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(
          market: Market.idx,
          initialSymbol: 'BBCA',
          autoRun: true,
          repository: offlineRepository(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Backtest'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Backtest'), findsOneWidget);
    expect(find.text('Win rate'), findsOneWidget);
    expect(find.text('Avg return'), findsOneWidget);
    expect(find.text('Profit factor'), findsOneWidget);
    expect(find.text('Max drawdown'), findsOneWidget);
    expect(find.text('Total signals'), findsOneWidget);
  });
}
