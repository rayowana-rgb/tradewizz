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
import 'package:tradewiz/services/moomoo_secret_store.dart';
import 'package:tradewiz/state/explore_filter_store.dart';
import 'package:tradewiz/widgets/category_badge.dart';

import 'helpers.dart';

/// In-memory secret persistence so tests never touch the Keychain.
class _MemSecret implements MoomooSecretPersistence {
  _MemSecret([this._v]);
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String secret) async => _v = secret;
  @override
  Future<void> clear() async => _v = null;
}

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

  testWidgets(
      'owner sees LIVE Buy-all on US; it places one real order per match',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    final repo = _liveBulkRepo(2, placed: placed);
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    // LIVE button is visible to the owner on US.
    final liveBtn = find.byKey(const Key('screener_buy_all_live_button'));
    expect(liveBtn, findsOneWidget);

    await tester.tap(liveBtn);
    await tester.pumpAndSettle();

    // Confirm is disabled until the real-money acknowledgement is checked.
    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('live_bulk_confirm_button')),
    );
    expect(confirm.onPressed, isNull);

    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // Two real Moomoo orders were placed (MARKET, BUY, confirm=true).
    expect(placed.length, 2);
    expect(placed.every((b) => b['side'] == 'BUY'), isTrue);
    expect(placed.every((b) => b['order_type'] == 'MARKET'), isTrue);
    expect(placed.every((b) => b['confirm'] == true), isTrue);
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.text('LIVE buy complete'), findsOneWidget);
  });

  testWidgets('LIVE Buy-all numeric keypad dismisses on tap outside',
      (tester) async {
    final repo = _liveBulkRepo(2, placed: <Map<String, dynamic>>[]);
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();

    // Focus the quantity field (this is what brings up the numeric keypad).
    final qtyField = find.byKey(const Key('live_bulk_qty_field'));
    await tester.tap(qtyField);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(
          find.descendant(of: qtyField, matching: find.byType(EditableText)))
          .focusNode
          .hasFocus,
      isTrue,
    );

    // Tapping outside the field (on the sheet title) dismisses the keypad.
    await tester.tap(find.byKey(const Key('live_bulk_title')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(
          find.descendant(of: qtyField, matching: find.byType(EditableText)))
          .focusNode
          .hasFocus,
      isFalse,
    );

    // And the Confirm button is reachable/visible.
    expect(find.byKey(const Key('live_bulk_confirm_button')), findsOneWidget);
  });

  testWidgets('LIVE Buy-all skips stocks already held', (tester) async {
    final placed = <Map<String, dynamic>>[];
    // 3 matches (AAPL0/1/2); AAPL1 is already held -> must be skipped, so
    // only AAPL0 and AAPL2 are bought.
    final repo = _liveBulkRepo(3, placed: placed, held: {'AAPL1'});
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();

    // The sheet announces the held-skip and sizes the run to 2 (not 3).
    // ("Buy all 2 · LIVE" shows in both the title and the confirm button.)
    expect(find.byKey(const Key('live_bulk_already_held')), findsOneWidget);
    expect(find.text('Buy all 2 · LIVE'), findsWidgets);

    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // Only the two non-held names were ordered; AAPL1 was never placed.
    final symbols = placed.map((b) => b['symbol']).toSet();
    expect(placed.length, 2);
    expect(symbols, {'AAPL0', 'AAPL2'});
    expect(symbols.contains('AAPL1'), isFalse);
  });

  testWidgets('LIVE Buy-all skips stocks bought today even if not held',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // 3 matches (AAPL0/1/2); AAPL1 was bought earlier today and already sold
    // (so it is NOT in positions) -> must still be skipped for today.
    final repo = _liveBulkRepo(3, placed: placed, boughtToday: {'AAPL1'});
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();

    // Skip is announced and the run is sized to 2 (not 3).
    expect(find.byKey(const Key('live_bulk_already_held')), findsOneWidget);
    expect(find.text('Buy all 2 · LIVE'), findsWidgets);

    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // AAPL1 (bought today, now flat) was never re-bought.
    final symbols = placed.map((b) => b['symbol']).toSet();
    expect(placed.length, 2);
    expect(symbols, {'AAPL0', 'AAPL2'});
    expect(symbols.contains('AAPL1'), isFalse);
  });

  testWidgets('LIVE Buy-all slider caps the run to the top N matches',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // 5 matches ranked AAPL0 (top) .. AAPL4; slider set to top 3.
    final repo = _liveBulkRepo(5, placed: placed);
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();

    // Defaults to all 5; the slider lets us cap the run.
    expect(find.byKey(const Key('live_bulk_topn_slider')), findsOneWidget);
    expect(find.text('All 5'), findsOneWidget);

    // The slider spans 1..5; tapping its horizontal centre selects the middle
    // value (3). Tapping is far more deterministic than a pixel-based drag.
    final slider = find.byKey(const Key('live_bulk_topn_slider'));
    await tester.tapAt(tester.getCenter(slider));
    await tester.pumpAndSettle();
    expect(find.text('Top 3'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // Only the top 3 ranked names were bought.
    final symbols = placed.map((b) => b['symbol']).toSet();
    expect(placed.length, 3);
    expect(symbols, {'AAPL0', 'AAPL1', 'AAPL2'});
  });

  testWidgets('non-owner never sees the LIVE Buy-all button', (tester) async {
    final repo = _liveBulkRepo(2);
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();
    await tester.pumpWidget(
      _wrapSignedIn(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screener_buy_all_button')), findsOneWidget);
    expect(find.byKey(const Key('screener_buy_all_live_button')),
        findsNothing);
  });

  testWidgets(
      'LIVE Buy-all counts \$1-min and MAS-evaluation rejects as skipped',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // 3 matches: AAPL0 succeeds, AAPL1 hits the \$1 fractional minimum,
    // AAPL2 needs the Singapore (MAS) suitability evaluation. Neither reject
    // should be reported as a hard failure.
    final repo = _liveBulkRepo(
      3,
      placed: placed,
      rejectWith: {
        'AAPL1': 'Fractional share orders require a minimum order amount '
            'of \$1.00. Please increase your order quantity and try again.',
        'AAPL2': 'As required by the Monetary Authority of Singapore, please '
            'complete the evaluation before trading.',
      },
    );
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // 1 placed, 2 skipped (not failed): no 'failed' line.
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.text('1 placed (LIVE)'), findsOneWidget);
    expect(find.textContaining('2 skipped'), findsOneWidget);
    expect(find.textContaining('failed'), findsNothing);
  });

  testWidgets('LIVE Buy-all dollar-per-stock derives qty from each price',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // Prices are 100, 101, 102 for AAPL0..AAPL2.
    final repo = _liveBulkRepo(3, placed: placed);
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();
    // Switch to dollar-per-stock mode and enter \$10.
    await tester.tap(find.text('\$ / stock'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('live_bulk_dollar_field')), '10');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // qty = 10 / price, rounded to 4 dp: 0.1, ~0.099, ~0.098.
    expect(placed.length, 3);
    expect(placed[0]['symbol'], 'AAPL0');
    expect((placed[0]['quantity'] as num).toDouble(), closeTo(0.1, 1e-9));
    expect((placed[1]['quantity'] as num).toDouble(),
        closeTo(10 / 101, 1e-4));
    expect(find.text('3 placed (LIVE)'), findsOneWidget);
  });

  testWidgets(
      'LIVE Buy-all retries a rate-limited order instead of failing it',
      (tester) async {
    final placed = <Map<String, dynamic>>[];
    // 3 matches; AAPL1 is rate-limited on its first attempt (Moomoo
    // "high frequency") and must succeed on retry, not count as failed.
    final repo = _liveBulkRepo(
      3,
      placed: placed,
      rateLimitOnce: {'AAPL1'},
    );
    final secret = MoomooSecretStore(persistence: _MemSecret('topsecret'));
    await secret.load();

    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrapOwner(
        ScreenerPage(
          market: Market.us,
          repository: repo,
          secretStore: secret,
          // Disable real-time pacing so the test runs instantly.
          liveBulkOrderGap: Duration.zero,
        ),
        repo,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const Key('screener_buy_all_live_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('live_bulk_qty_field')), '1');
    await tester.tap(find.byKey(const Key('live_bulk_ack')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('live_bulk_confirm_button')));
    await tester.pumpAndSettle(const Duration(milliseconds: 800));

    // AAPL1 was attempted twice (rate-limit then retry); all 3 end placed,
    // none failed.
    final aapl1Tries =
        placed.where((b) => b['symbol'] == 'AAPL1').length;
    expect(aapl1Tries, 2);
    expect(find.byKey(const Key('bulk_result_dialog')), findsOneWidget);
    expect(find.text('3 placed (LIVE)'), findsOneWidget);
    expect(find.textContaining('failed'), findsNothing);
  });
}

/// Sign-in wrap as the bridge OWNER (uid 2) for the LIVE Buy-all path.
Widget _wrapOwner(Widget child, StockRepository repo) {
  final auth = AuthStore()
    ..setSession(
        'JWT',
        const UserProfile(
            id: 2, email: 'owner@b.com', createdAt: '', updatedAt: ''));
  return AuthScope(store: auth, child: wrapApp(child, repository: repo));
}

/// US repo that returns [matchCount] matches and accepts REAL Moomoo order
/// placements, recording each placed body. [rejectWith] maps a match symbol to
/// a broker error detail returned as HTTP 400 (to exercise skip vs fail
/// classification).
StockRepository _liveBulkRepo(
  int matchCount, {
  List<Map<String, dynamic>>? placed,
  Map<String, String>? rejectWith,
  Set<String>? rateLimitOnce,
  Set<String>? held,
  Set<String>? boughtToday,
}) {
  var n = 0;
  final attempts = <String, int>{};
  final live = MockClient((req) async {
    final path = req.url.path;
    // Symbols bought today (held or already sold) so Buy-all skips them too.
    if (path.endsWith('/broker/moomoo/bought-today')) {
      return http.Response(
        jsonEncode({'symbols': (boughtToday ?? const <String>{}).toList()}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    // Live positions the account already holds (so Buy-all skips them).
    if (path.endsWith('/broker/moomoo/positions')) {
      return http.Response(
        jsonEncode({
          'positions': [
            for (final s in (held ?? const <String>{}))
              {
                'code': 'US.$s',
                'symbol': s,
                'quantity': 3.0,
                'can_sell_qty': 3.0,
                'cost_price': 100.0,
                'last_price': 100.0,
                'pl_val': 0.0,
                'pl_ratio': 0.0,
              },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/broker/moomoo/order/place')) {
      n++;
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      placed?.add(body);
      final sym = body['symbol'] as String;
      // Transient rate limit: fail the FIRST attempt for these symbols, then
      // succeed on the retry (exercises the throttle/retry path).
      if (rateLimitOnce != null && rateLimitOnce.contains(sym)) {
        final a = (attempts[sym] ?? 0) + 1;
        attempts[sym] = a;
        if (a == 1) {
          return http.Response(
            jsonEncode({
              'detail':
                  'Place Order request failed due to high frequency. '
                      'Maximum 15 times per 30 seconds.'
            }),
            400,
            headers: {'content-type': 'application/json'},
          );
        }
      }
      final detail = rejectWith?[sym];
      if (detail != null) {
        return http.Response(
          jsonEncode({'detail': detail}),
          400,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'order_id': 'live-$n',
          'symbol': body['symbol'],
          'side': body['side'],
          'quantity': body['quantity'],
          'order_type': body['order_type'],
          'status': 'SUBMITTED',
          'message': 'Order submitted.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final matches = List.generate(
      matchCount,
      (i) => {
        'symbol': 'AAPL$i',
        'name': 'Co $i',
        'score': (90 - i).toDouble(),
        'signal': 'BUY',
        'price': 100.0 + i,
        'change_percent': 1.0,
        'categories': ['bullish'],
      },
    );
    return http.Response(
      jsonEncode({
        'market': 'US',
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
