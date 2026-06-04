import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/screener_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/widgets/category_badge.dart';

void main() {
  testWidgets('Screener loads matches and shows category badges',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenerPage(
            market: Market.idx,
            repository: StockRepository(),
          ),
        ),
      ),
    );

    // Loading spinner first.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Resolve mocked latency.
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // Matches render with category badges.
    expect(find.byType(CategoryBadge), findsWidgets);
    expect(find.textContaining('IDX'), findsWidgets);
  });

  testWidgets('Category filter narrows results', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScreenerPage(
            market: Market.idx,
            repository: StockRepository(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    final before = tester.widgetList(find.byType(CategoryBadge)).length;

    // Tap the "Bearish" filter chip.
    await tester.tap(find.widgetWithText(FilterChip, 'Bearish'));
    await tester.pumpAndSettle();

    final after = tester.widgetList(find.byType(CategoryBadge)).length;
    expect(after, lessThanOrEqualTo(before));
  });
}
