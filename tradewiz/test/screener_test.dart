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
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/state/explore_filter_store.dart';
import 'package:tradewiz/widgets/category_badge.dart';

import 'helpers.dart';

/// A repository that returns [matchCount] IDX matches and accepts simulated
/// order placements, recording each placed body so the test can assert that
/// the bulk-buy fanned out one order per stock. Optionally fails the Nth+ order
/// with an "insufficient cash" error to exercise the skip path.
StockRepository _bulkBuyRepo(
  int matchCount, {
  List<Map<String, dynamic>>? placed,
  int? cashRunsOutAfter,
}) {
  var placedCount = 0;
  final live = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/order/place')) {
      placedCount++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      placed?.add(body);
      if (cashRunsOutAfter != null && placedCount > cashRunsOutAfter) {
        return http.Response(
          jsonEncode({'detail': 'Insufficient simulated cash for this order.'}),
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'order_id': 'sim-$placedCount',
          'symbol': body['symbol'],
          'market': body['market'],
          'side': body['side'],
          'quantity': body['quantity'],
          'price': body['price'] ?? 1000.0,
          'value': 1000.0,
          'status': 'FILLED_SIMULATED',
          'realized_pnl': 0.0,
          'cash_after': 1000000.0,
          'simulated': true,
          'message': 'Simulated order filled. No real broker order was sent.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Default: the /screen response.
    final matches = List.generate(
      matchCount,
      (i) => {
        'symbol': 'IDX${(i + 1).toString().padLeft(2, '0')}',
        'name': 'Co $i',
        'score': (90 - i).toDouble(),
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
        'generated_at': '2026-06-10T00:00:00Z',
        'total_count': matchCount,
        'returned_count': matchCount,
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

/// Wraps a page with a signed-in AuthScope (so the sim endpoints are reachable)
/// plus the standard RepositoryScope harness.
Widget _wrapSignedIn(Widget child, StockRepository repo) {
  final auth = AuthStore()
    ..setSession('JWT',
        const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return AuthScope(
    store: auth,
    child: wrapApp(child, repository: repo),
  );
}

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
  // The Explore filter store is a process-wide singleton (so selections survive
  // tab switches in the real app). Reset it before each test for isolation.
  setUp(ExploreFilterStore.instance.reset);

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
    // Broker hand-off now lives inside this swipe menu (below Buy / Sell),
    // not on the card next to the score.
    expect(
      find.byKey(const Key('screener_action_open_broker')),
      findsOneWidget,
    );
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

  // --- Phase 11B: liquidity-first breakdown on the Explore card --------
  testWidgets('Explore card shows the liquidity contribution',
      (tester) async {
    final live = MockClient((req) async {
      return http.Response(
        jsonEncode({
          'market': 'IDX',
          'matches': [
            {
              'symbol': 'BBCA',
              'name': 'Bank Central Asia',
              'score': 74.0,
              'signal': 'BUY',
              'price': 9850.0,
              'change_percent': 1.2,
              'categories': ['bullish'],
              'base_score': 74.0,
              'category_bonus': 5,
              'conviction_score': 10,
              'final_score': 92.0,
              'liquidity_score': 88.0,
              'participation_score': 88.0,
              'value_traded_today': 82000000000.0,
              'avg_value_traded_20d': 55000000000.0,
              'volume_today': 9000000.0,
              'avg_volume_20d': 3700000.0,
              'volume_ratio_20d': 2.4,
              'value_traded_ratio_20d': 1.5,
            },
          ],
          'generated_at': '2026-06-10T00:00:00Z',
          'total_count': 1,
          'returned_count': 1,
          'limit': 50,
          'min_score': 0,
          'categories': <String>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final repo = StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: live,
      ),
    );
    await tester.pumpWidget(
      wrapApp(ScreenerPage(market: Market.idx, repository: repo)),
    );
    await tester.pumpAndSettle();

    // Final Score remains the hero metric (the pill shows 92).
    expect(find.text('92'), findsWidgets);
    // Liquidity is a first-class breakdown entry.
    expect(find.textContaining('Liquidity'), findsWidgets);
    // Secondary participation read-out is rendered.
    expect(
        find.byKey(const Key('screener_liquidity_line')), findsOneWidget);
    expect(find.textContaining('avg 20D'), findsOneWidget);
    expect(find.textContaining('2.4x vol'), findsOneWidget);
  });

  // --- Bulk buy: buy every filtered match in one go (simulation) --------
  testWidgets('Buy-all places one simulated order per match', (tester) async {
    final placed = <Map<String, dynamic>>[];
    final repo = _bulkBuyRepo(3, placed: placed);
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(market: Market.idx, repository: repo),
        repo,
      ),
    );
    await tester.pumpAndSettle();

    // The bulk action bar is shown above the list.
    expect(find.byKey(const Key('screener_buy_all_button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screener_buy_all_button')));
    await tester.pumpAndSettle();

    // Configure: qty 50, Market, confirm.
    await tester.enterText(find.byKey(const Key('bulk_qty_field')), '50');
    await tester.tap(find.byKey(const Key('bulk_confirm_button')));
    await tester.pumpAndSettle();

    // One order per match, all BUY/MARKET with the chosen quantity.
    expect(placed.length, 3);
    expect(placed.every((b) => b['side'] == 'BUY'), isTrue);
    expect(placed.every((b) => b['order_type'] == 'MARKET'), isTrue);
    expect(placed.every((b) => (b['quantity'] as num) == 50), isTrue);
    expect(placed.map((b) => b['symbol']).toSet(),
        {'IDX01', 'IDX02', 'IDX03'});

    // Summary dialog reports 3 filled.
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.textContaining('3 filled'), findsOneWidget);
  });

  testWidgets('Buy-all Limit uses each stock\'s last price', (tester) async {
    final placed = <Map<String, dynamic>>[];
    final repo = _bulkBuyRepo(2, placed: placed);
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(market: Market.idx, repository: repo),
        repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_buy_all_button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('bulk_qty_field')), '10');
    await tester.tap(find.byKey(const Key('bulk_type_limit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk_confirm_button')));
    await tester.pumpAndSettle();

    expect(placed.length, 2);
    expect(placed.every((b) => b['order_type'] == 'LIMIT'), isTrue);
    // IDX01 price 1000, IDX02 price 1001 (from the mock generator).
    expect(placed[0]['price'], 1000.0);
    expect(placed[1]['price'], 1001.0);
  });

  testWidgets('Buy-all skips orders that run out of simulated cash',
      (tester) async {
    // 4 matches, but cash runs out after the 2nd fill -> 2 filled, 2 skipped.
    final repo = _bulkBuyRepo(4, cashRunsOutAfter: 2);
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(market: Market.idx, repository: repo),
        repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_buy_all_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk_confirm_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('2 filled'), findsOneWidget);
    expect(find.textContaining('2 skipped'), findsOneWidget);
  });

  testWidgets(
      'Tapping outside the progress dialog asks to stop; Yes halts the run',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // Delay each simulated order so the run is observably in-flight.
    final repo = _delayedBulkBuyRepo(8, placed: placed,
        delay: const Duration(milliseconds: 60));
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(market: Market.idx, repository: repo),
        repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_buy_all_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk_confirm_button')));
    // Let the run start (progress dialog is up, a couple orders in flight).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byKey(const Key('bulk_progress_dialog')), findsOneWidget);

    // Tap OUTSIDE the card (near the top-left corner) -> the
    // "stop the purchase?" confirmation appears.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bulk_cancel_confirm')), findsOneWidget);

    // Choose Yes -> the run stops; let pending order(s) settle.
    await tester.tap(find.byKey(const Key('bulk_cancel_yes')));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Stopped early: fewer than all 8 orders were placed.
    expect(placed.length, lessThan(8));
    // Summary reflects the cancellation.
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.text('Bulk buy stopped'), findsOneWidget);
  });

  testWidgets('Tapping outside then No keeps the run going', (tester) async {
    final placed = <Map<String, dynamic>>[];
    // Generous per-order delay so the run can't finish while we interact.
    final repo = _delayedBulkBuyRepo(3, placed: placed,
        delay: const Duration(milliseconds: 120));
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(market: Market.idx, repository: repo),
        repo,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screener_buy_all_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bulk_confirm_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // Open the confirm, then choose No.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bulk_cancel_confirm')), findsOneWidget);

    // Choose No -> dismiss the confirm and let the run finish normally.
    await tester.tap(find.byKey(const Key('bulk_cancel_no')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // All 3 orders went through; the run completed (not cancelled).
    expect(placed.length, 3);
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.text('Bulk buy complete'), findsOneWidget);
  });
}

/// Like [_bulkBuyRepo] but each /sim/order/place response is delayed so the
/// bulk run is observably in flight (needed to test cancellation).
StockRepository _delayedBulkBuyRepo(
  int matchCount, {
  required Duration delay,
  List<Map<String, dynamic>>? placed,
}) {
  var placedCount = 0;
  final live = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/order/place')) {
      await Future<void>.delayed(delay);
      placedCount++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      placed?.add(body);
      return http.Response(
        jsonEncode({
          'order_id': 'sim-$placedCount',
          'symbol': body['symbol'],
          'market': body['market'],
          'side': body['side'],
          'quantity': body['quantity'],
          'price': body['price'] ?? 1000.0,
          'value': 1000.0,
          'status': 'FILLED_SIMULATED',
          'realized_pnl': 0.0,
          'cash_after': 1000000.0,
          'simulated': true,
          'message': 'Simulated order filled.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final matches = List.generate(
      matchCount,
      (i) => {
        'symbol': 'IDX${(i + 1).toString().padLeft(2, '0')}',
        'name': 'Co $i',
        'score': (90 - i).toDouble(),
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
        'generated_at': '2026-06-10T00:00:00Z',
        'total_count': matchCount,
        'returned_count': matchCount,
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
