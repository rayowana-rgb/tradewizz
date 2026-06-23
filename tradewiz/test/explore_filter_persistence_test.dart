import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/screener_category.dart';
import 'package:tradewiz/pages/screener_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/state/explore_filter_store.dart';

import 'helpers.dart';

/// A repository whose /screen response returns a small, deterministic set of
/// rows so filter selections are exercisable. Always 200 "live".
StockRepository _repo() {
  final live = MockClient((req) async {
    return http.Response(
      jsonEncode({
        'market': 'IDX',
        'matches': [
          {
            'symbol': 'BBCA',
            'name': 'Bank Central Asia',
            'score': 90.0,
            'signal': 'BUY',
            'price': 9850.0,
            'change_percent': 1.2,
            'categories': ['bullish'],
          },
          {
            'symbol': 'TLKM',
            'name': 'Telkom',
            'score': 80.0,
            'signal': 'HOLD',
            'price': 3200.0,
            'change_percent': -0.4,
            'categories': ['pullback'],
          },
          {
            'symbol': 'XBND',
            'name': 'Bond ETF',
            'score': 70.0,
            'signal': 'HOLD',
            'price': 1000.0,
            'change_percent': 0.1,
            'categories': <String>[],
            'is_etf': true,
          },
        ],
        'generated_at': '2026-06-10T00:00:00Z',
        'total_count': 3,
        'returned_count': 3,
        'limit': 50,
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

/// Minimal two-tab shell mirroring production's IndexedStack so we can test the
/// Home <-> Explore round-trip. Explore reads/writes the shared filter store.
class _MiniShell extends StatefulWidget {
  const _MiniShell({required this.repo});
  final StockRepository repo;

  @override
  State<_MiniShell> createState() => _MiniShellState();
}

class _MiniShellState extends State<_MiniShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      ScreenerPage(market: Market.idx, repository: widget.repo),
      const Center(child: Text('HOME TAB')),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('to_explore'),
              onPressed: () => setState(() => _index = 0),
              child: const Text('Explore'),
            ),
          ),
          Expanded(
            child: TextButton(
              key: const Key('to_home'),
              onPressed: () => setState(() => _index = 1),
              child: const Text('HomeTab'),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _pump(WidgetTester tester) async {
  // The filters bottom sheet is tall; give it a roomy surface so its chips and
  // the Apply button are on-screen and hit-testable.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(wrapApp(_MiniShell(repo: _repo())));
  await tester.pumpAndSettle();
}

/// Tap a finder, scrolling it into view first when it sits below the fold.
Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _switchToHomeAndBack(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('to_home')));
  await tester.pumpAndSettle();
  expect(find.text('HOME TAB'), findsOneWidget);
  await tester.tap(find.byKey(const Key('to_explore')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(ExploreFilterStore.instance.reset);

  testWidgets('selected category persists across Home <-> Explore',
      (tester) async {
    await _pump(tester);

    // Open the filter sheet, pick a category (Pullback) and apply.
    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Pullback'));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));

    // Filter button shows the active count.
    expect(find.text('Filters (1)'), findsOneWidget);

    await _switchToHomeAndBack(tester);

    // Selection survived: store + UI still reflect Pullback.
    expect(ExploreFilterStore.instance.categoryFilter,
        ScreenerCategory.pullback);
    expect(find.text('Filters (1)'), findsOneWidget);
  });

  testWidgets('search query persists across tab switch', (tester) async {
    await _pump(tester);

    await tester.enterText(find.byType(TextField).first, 'BBCA');
    await tester.pumpAndSettle();
    expect(ExploreFilterStore.instance.query, 'BBCA');

    await _switchToHomeAndBack(tester);

    expect(ExploreFilterStore.instance.query, 'BBCA');
    // The text field still shows the restored query.
    final field = tester.widget<TextField>(find.byType(TextField).first);
    expect(field.controller?.text, 'BBCA');
  });

  testWidgets('min score persists across tab switch', (tester) async {
    await _pump(tester);

    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.widgetWithText(ChoiceChip, '≥ 70'));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));
    expect(find.text('Filters (1)'), findsOneWidget);

    await _switchToHomeAndBack(tester);

    expect(ExploreFilterStore.instance.minScore, 70.0);
    expect(find.text('Filters (1)'), findsOneWidget);
  });

  testWidgets('clear filters resets the count to 0', (tester) async {
    await _pump(tester);

    // Set two filters: category + min score.
    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Bullish'));
    await _tap(tester, find.widgetWithText(ChoiceChip, '≥ 90'));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));
    expect(find.text('Filters (2)'), findsOneWidget);

    // Reopen the sheet and clear everything via Reset, then apply.
    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.widgetWithText(OutlinedButton, 'Reset'));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));

    // Count is back to 0 ("Filters" with no parens), and stays cleared.
    expect(find.text('Filters'), findsOneWidget);
    expect(ExploreFilterStore.instance.categoryFilter, isNull);
    expect(ExploreFilterStore.instance.minScore, 0);

    await _switchToHomeAndBack(tester);
    expect(find.text('Filters'), findsOneWidget);
  });

  testWidgets('reopening the filter sheet shows the previous selection',
      (tester) async {
    await _pump(tester);

    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.widgetWithText(ChoiceChip, 'Bullish'));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));

    await _switchToHomeAndBack(tester);

    // Reopen the sheet: the Bullish chip must come up pre-selected.
    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Bullish'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('instrument-type filter shows only ETFs and persists',
      (tester) async {
    await _pump(tester);

    // All three rows visible before filtering (1 ETF + 2 stocks).
    expect(find.text('XBND'), findsOneWidget);
    expect(find.text('BBCA'), findsOneWidget);

    // Open the sheet and pick the ETFs type chip.
    await _tap(tester, find.byKey(const Key('screener_filters_button')));
    await _tap(tester, find.byKey(const Key('screener_type_etf')));
    await _tap(tester, find.byKey(const Key('screener_filters_apply')));

    // Only the ETF row remains; stocks are filtered out.
    expect(find.text('XBND'), findsOneWidget);
    expect(find.text('BBCA'), findsNothing);
    expect(find.text('TLKM'), findsNothing);
    expect(find.text('Filters (1)'), findsOneWidget);
    expect(ExploreFilterStore.instance.instrumentType,
        InstrumentTypeFilter.etf);

    // Survives a tab round-trip.
    await _switchToHomeAndBack(tester);
    expect(ExploreFilterStore.instance.instrumentType,
        InstrumentTypeFilter.etf);
    expect(find.text('XBND'), findsOneWidget);
    expect(find.text('BBCA'), findsNothing);
  });
}
