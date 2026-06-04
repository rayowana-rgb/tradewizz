import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/screener_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/widgets/category_badge.dart';

import 'helpers.dart';

/// Builds a live repository whose /screen response reports [total] matches but
/// returns only `min(limit, total)` of them, so Load More is exercisable.
StockRepository _paginatedRepo(int total) {
  final live = MockClient((req) async {
    final limit =
        int.tryParse(req.url.queryParameters['limit'] ?? '50') ?? 50;
    final returned = limit < total ? limit : total;
    final matches = List.generate(
      returned,
      (i) => {
        'symbol': 'IDX${(i + 1).toString().padLeft(2, '0')}',
        'name': 'Co $i',
        'score': (100 - i).toDouble(),
        'signal': 'BUY',
        'price': 1000.0 + i,
        'change_percent': 1.0,
        'categories': ['bullish'],
      },
    );
    return http.Response(
      jsonEncode({
        'market': 'IDX',
        'matches': matches,
        'generated_at': '2026-06-04T00:00:00Z',
        'total_count': total,
        'returned_count': returned,
        'limit': limit,
        'min_score': 0,
        'categories': <String>[],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: live,
    ),
  );
}

Future<void> _loadScreener(WidgetTester tester) async {
  await tester.pumpWidget(
    wrapApp(
      ScreenerPage(market: Market.idx, repository: offlineRepository()),
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
        ScreenerPage(market: Market.idx, repository: offlineRepository()),
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

  testWidgets('shows "Showing X of Y" from fallback metadata', (tester) async {
    await _loadScreener(tester);
    // Footer is at the bottom of the list; scroll it into view.
    await tester.scrollUntilVisible(
      find.text('Showing 10 of 10'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Showing 10 of 10'), findsOneWidget);
  });

  testWidgets('Load More increases limit and fetches more rows',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(ScreenerPage(market: Market.idx, repository: _paginatedRepo(120))),
    );
    await tester.pumpAndSettle();

    final scrollable = find.byType(Scrollable).last;

    // Initial page: 50 of 120, with a Load more button.
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, 'Load more'), 400,
      scrollable: scrollable,
    );
    expect(find.text('Showing 50 of 120'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Showing 100 of 120'), 400, scrollable: scrollable,
    );
    expect(find.text('Showing 100 of 120'), findsOneWidget);

    // One more press: limit 150 -> all 120 shown, button disappears.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Load more'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Showing 120 of 120'), 400, scrollable: scrollable,
    );
    expect(find.text('Showing 120 of 120'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Load more'), findsNothing);
  });
}
