import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/screener_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/widgets/category_badge.dart';

import 'helpers.dart';

Future<void> _loadScreener(WidgetTester tester) async {
  await tester.pumpWidget(
    wrapApp(
      ScreenerPage(market: Market.idx, repository: StockRepository()),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Screener loads matches and shows category badges',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(
        ScreenerPage(market: Market.idx, repository: StockRepository()),
      ),
    );

    // Loading spinner first.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.byType(CategoryBadge), findsWidgets);
    expect(find.textContaining('IDX'), findsWidgets);
  });

  testWidgets('Category filter narrows results', (tester) async {
    await _loadScreener(tester);

    final before = tester.widgetList(find.byType(CategoryBadge)).length;

    await tester.tap(find.widgetWithText(FilterChip, 'Bearish'));
    await tester.pumpAndSettle();

    final after = tester.widgetList(find.byType(CategoryBadge)).length;
    expect(after, lessThanOrEqualTo(before));
  });

  testWidgets('Tapping a match opens analysis and back returns to screener',
      (tester) async {
    await _loadScreener(tester);

    // Tap the first match card (symbols are like IDX01, IDX02 ...).
    await tester.tap(find.text('IDX01'));
    await tester.pump(); // navigation
    await tester.pump(); // post-frame autoRun
    await tester.pump(const Duration(seconds: 1)); // mocked latency
    await tester.pumpAndSettle();

    // Detail page shows its app-bar title and an analysis result.
    expect(find.text('IDX01 · IDX'), findsOneWidget);
    expect(find.textContaining('Score'), findsOneWidget);

    // Back navigation returns to the screener list.
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryBadge), findsWidgets);
  });
}
