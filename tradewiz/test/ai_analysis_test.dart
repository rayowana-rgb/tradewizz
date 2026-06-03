import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';

void main() {
  testWidgets('AI Analysis form produces a placeholder result', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiAnalysisPage(
            market: Market.idx,
            repository: StockRepository(),
          ),
        ),
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
}
