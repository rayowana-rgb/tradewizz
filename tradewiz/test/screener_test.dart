import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/broker.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/order_ticket_page.dart';
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

/// Repository whose /screen response carries market-close cache metadata.
StockRepository _cachedRepo({
  required bool cached,
  required String marketStatus, // 'OPEN' | 'CLOSED'
  String? warning,
}) {
  final live = MockClient((req) async {
    final body = <String, dynamic>{
      'market': 'HKEX',
      'matches': [
        {
          'symbol': '0700',
          'name': 'Tencent',
          'score': 91.0,
          'signal': 'BUY',
          'price': 412.6,
          'change_percent': 1.2,
          'categories': ['bullish'],
        },
      ],
      'generated_at': '2026-06-07T08:30:00Z',
      'total_count': 1,
      'returned_count': 1,
      'limit': 50,
      'min_score': 0,
      'categories': <String>[],
      'cached': cached,
      'market_status': marketStatus,
      'market_date': '2026-06-07',
      'next_refresh_rule': 'Will refresh after next market close',
    };
    if (warning != null) body['warning'] = warning;
    return http.Response(
      jsonEncode(body),
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

  // --- Market-close cache banner ------------------------------------------
  testWidgets('cached badge + generated_at render (market closed)',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(ScreenerPage(
        market: Market.hkex,
        repository: _cachedRepo(cached: true, marketStatus: 'CLOSED'),
      )),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('screener_cache_label')), findsOneWidget);
    expect(find.text('Cached market-close result'), findsOneWidget);
    // generated_at is rendered (formatted from 2026-06-07T08:30:00Z).
    expect(find.byKey(const Key('screener_generated_at')), findsOneWidget);
    // Closed market shows the refresh rule, not the open-hours warning.
    expect(find.byKey(const Key('screener_refresh_rule')), findsOneWidget);
    expect(find.byKey(const Key('screener_open_warning')), findsNothing);
  });

  testWidgets('open-market warning renders when market is open',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(ScreenerPage(
        market: Market.hkex,
        repository: _cachedRepo(cached: true, marketStatus: 'OPEN'),
      )),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('screener_cache_label')), findsOneWidget);
    expect(find.byKey(const Key('screener_open_warning')), findsOneWidget);
    expect(
      find.textContaining('latest saved result to avoid slow loading'),
      findsOneWidget,
    );
  });

  testWidgets('server warning is surfaced when open', (tester) async {
    await tester.pumpWidget(
      wrapApp(ScreenerPage(
        market: Market.hkex,
        repository: _cachedRepo(
          cached: true,
          marketStatus: 'OPEN',
          warning: 'Screening refresh is only allowed after market close.',
        ),
      )),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screener_cache_warning')), findsOneWidget);
    expect(
      find.textContaining('only allowed after market close'),
      findsOneWidget,
    );
  });

  testWidgets('no cache banner when server omits cache metadata',
      (tester) async {
    // Offline/mock repo response has no cache fields -> banner hidden.
    await _loadScreener(tester);
    expect(find.byKey(const Key('screener_cache_label')), findsNothing);
  });

  testWidgets('Swipe-left on a row reveals the Buy/Sell menu (no delete)',
      (tester) async {
    await _loadScreener(tester);

    final before = tester.widgetList(find.byType(CategoryBadge)).length;
    await tester.drag(find.text('IDX01'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    // Action menu appears with both Buy and Sell + the simulation disclaimer.
    expect(find.byKey(const Key('screener_action_menu')), findsOneWidget);
    expect(find.byKey(const Key('screener_action_buy')), findsOneWidget);
    expect(find.byKey(const Key('screener_action_sell')), findsOneWidget);
    expect(
      find.text('Simulation mode only. No real broker order will be sent.'),
      findsOneWidget,
    );

    // Dismiss the sheet; the row was NOT deleted.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    final after = tester.widgetList(find.byType(CategoryBadge)).length;
    expect(after, before);
    expect(find.text('IDX01'), findsOneWidget);
  });

  testWidgets('Swipe-left Buy opens the simulated order ticket (BUY)',
      (tester) async {
    await _loadScreener(tester);
    await tester.drag(find.text('IDX01'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_action_buy')));
    await tester.pumpAndSettle();

    final ticket =
        tester.widget<OrderTicketPage>(find.byType(OrderTicketPage));
    expect(ticket.symbol, 'IDX01');
    expect(ticket.market, Market.idx);
    expect(ticket.side, OrderSide.buy);
    // Simulation banner is shown.
    expect(find.byKey(const Key('sim_warning_banner')), findsOneWidget);
  });

  testWidgets('Swipe-left Sell opens the simulated order ticket (SELL)',
      (tester) async {
    await _loadScreener(tester);
    await tester.drag(find.text('IDX01'), const Offset(-400, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_action_sell')));
    await tester.pumpAndSettle();

    final ticket =
        tester.widget<OrderTicketPage>(find.byType(OrderTicketPage));
    expect(ticket.symbol, 'IDX01');
    expect(ticket.market, Market.idx);
    expect(ticket.side, OrderSide.sell);
    expect(find.byKey(const Key('sim_warning_banner')), findsOneWidget);
  });
}
