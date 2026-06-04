import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/watchlist_store.dart';

import 'helpers.dart';

void main() {
  testWidgets('AI Analysis form produces a placeholder result', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        AiAnalysisPage(market: Market.idx, repository: StockRepository()),
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
          repository: StockRepository(),
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
          repository: StockRepository(),
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
    await tester.tap(find.widgetWithText(FilledButton, 'Save to Watchlist'));
    await tester.pumpAndSettle();

    expect(store.contains('BBCA', Market.idx), isTrue);
    expect(find.text('Saved to Watchlist'), findsOneWidget);
  });
}
