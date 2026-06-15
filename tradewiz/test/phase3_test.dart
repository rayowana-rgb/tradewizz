import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/dashboard_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';
import 'package:tradewiz/widgets/auto_watchlist.dart';
import 'package:tradewiz/models/phase3.dart';
import 'package:tradewiz/services/portfolio_health_cache.dart';
import 'package:tradewiz/widgets/global_rotation.dart';
import 'package:tradewiz/widgets/rebalance.dart';

// --- Backend fixtures -------------------------------------------------------
Map<String, dynamic> _suggestionsBody() => {
      'generated_at': '2026-06-09T01:00:00Z',
      'session_date': '2026-06-09',
      'max_suggestions_per_day': 10,
      'enabled': true,
      'suggestions': [
        {
          'symbol': 'NVDA',
          'market': 'US',
          'name': 'NVIDIA',
          'score': 96,
          'signal': 'BUY',
          'origin': 'RADAR',
          'reason': 'Strong momentum, leading relative strength.',
          'market_regime': 'BULL',
          'relative_strength': 88.0,
          'liquidity': 8e9,
          'owned': false,
        },
        {
          'symbol': 'PLTR',
          'market': 'US',
          'name': 'Palantir',
          'score': 93,
          'signal': 'BUY',
          'origin': 'MULTIBAGGER',
          'reason': 'Acceleration trend + relative strength.',
          'market_regime': 'BULL',
          'relative_strength': 80.0,
          'liquidity': 5e9,
          'owned': false,
        },
      ],
    };

Map<String, dynamic> _applyBody(int count) => {
      'applied': [
        for (var i = 0; i < count; i++)
          {
            'symbol': i == 0 ? 'NVDA' : 'PLTR',
            'market': 'US',
            'name': i == 0 ? 'NVIDIA' : 'Palantir',
            'source': 'AUTO_WATCHLIST_AI',
            'reason': 'AI pick',
            'score_at_added': i == 0 ? 96 : 93,
            'market_regime_at_added': 'BULL',
            'added_at': '2026-06-09T01:00:00Z',
          },
      ],
      'skipped': [],
      'count': count,
      'simulated': true,
    };

Map<String, dynamic> _settingsBody() => {
      'enabled': true,
      'markets': [],
      'min_score': 85.0,
      'max_per_day': 10,
      'include_multibagger': true,
      'include_daily_picks': true,
    };

Map<String, dynamic> _rebalanceBody({bool empty = false}) => {
      'user_id': 1,
      'profile': 'Balanced',
      'portfolio_score': 72,
      'cash_allocation': 8.0,
      'actions': empty
          ? []
          : [
              {
                'symbol': 'TPIA',
                'market': 'IDX',
                'name': 'TPIA',
                'action': 'REDUCE',
                'reason': 'Reduce: position concentration too high (42%).',
                'current_weight': 42.1,
                'target_weight': 20.0,
                'priority': 'HIGH',
                'score': 70,
                'quality_score': 65,
              },
              {
                'symbol': 'NVDA',
                'market': 'US',
                'name': 'NVDA',
                'action': 'ADD',
                'reason': 'Strong name below its 20% target.',
                'current_weight': 8.0,
                'target_weight': 20.0,
                'priority': 'MEDIUM',
                'score': 94,
                'quality_score': 88,
              },
            ],
      'summary': 'Portfolio score 72, cash 8%. Recommended: 1 reduce, 1 add.',
      'warnings': [],
      'high_priority_count': empty ? 0 : 1,
      'estimated_score_improvement': empty ? 0.0 : 3.0,
      'simulated': true,
    };

Map<String, dynamic> _rotationBody() => {
      'generated_at': '2026-06-09T01:00:00Z',
      'session_date': '2026-06-09',
      'best_market': 'US',
      'rotation_summary': 'US and India show the strongest opportunity breadth.',
      'markets': [
        {
          'market': 'US',
          'rotation_score': 88,
          'rank': 1,
          'regime': 'BULL',
          'top_score_average': 86,
          'elite_count': 14,
          'strong_count': 52,
          'breadth': 61.2,
          'liquidity': 90.0,
          'volatility': 40.0,
          'recommendation': 'OVERWEIGHT',
        },
        {
          'market': 'INDIA',
          'rotation_score': 81,
          'rank': 2,
          'regime': 'BULL',
          'top_score_average': 83,
          'elite_count': 9,
          'strong_count': 40,
          'breadth': 58.0,
          'liquidity': 85.0,
          'volatility': 38.0,
          'recommendation': 'OVERWEIGHT',
        },
        {
          'market': 'VIETNAM',
          'rotation_score': 22,
          'rank': 3,
          'regime': 'BEAR',
          'top_score_average': 40,
          'elite_count': 0,
          'strong_count': 1,
          'breadth': 20.0,
          'liquidity': 50.0,
          'volatility': 70.0,
          'recommendation': 'AVOID',
        },
      ],
      'simulated': true,
    };

StockRepository _repo({List<String>? appliedCalls}) {
  final fake = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic>? body;
    if (path.endsWith('/auto-watchlist/suggestions')) {
      body = _suggestionsBody();
    } else if (path.endsWith('/auto-watchlist/apply')) {
      appliedCalls?.add(req.body);
      body = _applyBody(2);
    } else if (path.endsWith('/auto-watchlist/settings')) {
      body = _settingsBody();
    } else if (path.endsWith('/portfolio/rebalance')) {
      body = _rebalanceBody();
    } else if (path.endsWith('/sim/positions')) {
      // Hold both names referenced by the rebalance body so the reconcile
      // (drop actions for non-held symbols) keeps them.
      body = {
        'positions': [
          {
            'symbol': 'TPIA',
            'market': 'IDX',
            'quantity': 1200.0,
            'avg_price': 4000.0,
          },
          {
            'symbol': 'NVDA',
            'market': 'US',
            'quantity': 10.0,
            'avg_price': 800.0,
          },
        ],
      };
    } else if (path.endsWith('/rotation/global')) {
      body = _rotationBody();
    }
    if (body != null) {
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
}

AuthStore _loggedIn() {
  final s = AuthStore();
  s.setSession('JWT',
      const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return s;
}

Widget _wrap(Widget child, StockRepository repo, {WatchlistStore? watchlist}) {
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: _loggedIn(),
      child: WatchlistScope(
        store: watchlist ?? WatchlistStore(),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

void main() {
  // === Auto Watchlist AI ===================================================
  testWidgets('Auto Watchlist card shows suggested count + actions',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const AutoWatchlistCard(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auto_watchlist_card')), findsOneWidget);
    expect(find.byKey(const Key('auto_watchlist_count')), findsOneWidget);
    expect(find.textContaining('2 new pick'), findsOneWidget);
    expect(find.byKey(const Key('auto_watchlist_apply_all')), findsOneWidget);
    expect(find.byKey(const Key('auto_watchlist_review')), findsOneWidget);
    expect(find.text('AI PICK'), findsOneWidget);
  });

  testWidgets('Apply All adds suggestions to the watchlist', (tester) async {
    final calls = <String>[];
    final store = WatchlistStore();
    final repo = _repo(appliedCalls: calls);
    await tester.pumpWidget(
        _wrap(const AutoWatchlistCard(), repo, watchlist: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('auto_watchlist_apply_all')));
    await tester.pumpAndSettle();

    expect(calls, isNotEmpty); // apply endpoint was called
    // Applied names mirrored to the client-side watchlist store.
    expect(store.contains('NVDA', store.items.first.market), isTrue);
    expect(store.items.length, 2);
  });

  testWidgets('Review opens the AI Suggestions page with Add/Ignore',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const AutoWatchlistCard(), repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('auto_watchlist_review')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ai_suggestions_list')), findsOneWidget);
    expect(find.byKey(const Key('ai_suggestion_NVDA')), findsOneWidget);
    expect(find.byKey(const Key('ai_suggestion_add_NVDA')), findsOneWidget);
    expect(find.byKey(const Key('ai_suggestion_ignore_NVDA')), findsOneWidget);
    expect(find.byKey(const Key('ai_suggestions_add_all')), findsOneWidget);
  });

  testWidgets('Ignore removes a suggestion from the review list',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const AutoWatchlistCard(), repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auto_watchlist_review')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ai_suggestion_ignore_NVDA')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ai_suggestion_NVDA')), findsNothing);
    expect(find.byKey(const Key('ai_suggestion_PLTR')), findsOneWidget);
  });

  // === Portfolio Rebalancing AI ===========================================
  testWidgets('Rebalance card shows action + HIGH counts + est improvement',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const RebalanceCard(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rebalance_card')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_action_count')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_high_count')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_score_improve')), findsOneWidget);
    // 2 non-HOLD actions, 1 HIGH, +3 est.
    expect(find.text('2'), findsWidgets);
    expect(find.text('+3'), findsOneWidget);
  });

  testWidgets('Rebalance detail lists ADD/REDUCE actions + buttons',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const RebalanceCard(), repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rebalance_card')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rebalance_detail_list')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_action_TPIA')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_action_NVDA')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_buy_TPIA')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_sell_TPIA')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_analysis_TPIA')), findsOneWidget);
    expect(find.text('REDUCE'), findsWidgets);
    expect(find.text('ADD'), findsWidgets);
  });

  testWidgets(
      'Selling from Rebalance shows held lots + drag slider in the ticket',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const RebalanceCard(), repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rebalance_card')));
    await tester.pumpAndSettle();

    // Sell the held TPIA position -> ticket opens with holdings info + slider.
    await tester.tap(find.byKey(const Key('rebalance_sell_TPIA')));
    await tester.pumpAndSettle();

    // 1,200 shares @ 100/lot = 12 lots shown, and the drag slider is present.
    expect(find.byKey(const Key('sell_qty_slider')), findsOneWidget);
    expect(find.textContaining('1200 shares (12 lots)'), findsWidgets);
  });

  testWidgets(
      'Rebalance detail drops an action for a symbol that is no longer held',
      (tester) async {
    // Fresh report (rare, but possible from a stale backend snapshot or a
    // race) lists GGRM EXIT even though positions only hold TPIA. The UI must
    // reconcile against live holdings and never show the phantom action.
    final fake = MockClient((req) async {
      final path = req.url.path;
      if (path.endsWith('/portfolio/rebalance')) {
        return http.Response(
            jsonEncode({
              'profile': 'Balanced',
              'portfolio_score': 70,
              'cash_allocation': 10.0,
              'actions': [
                {
                  'symbol': 'TPIA',
                  'market': 'IDX',
                  'action': 'REDUCE',
                  'reason': 'Trim concentration.',
                  'current_weight': 40.0,
                  'target_weight': 20.0,
                  'priority': 'HIGH',
                },
                {
                  'symbol': 'GGRM',
                  'market': 'IDX',
                  'action': 'EXIT',
                  'reason': 'Weak.',
                  'current_weight': 0.0,
                  'target_weight': 0.0,
                  'priority': 'HIGH',
                },
              ],
              'summary': 'x',
              'warnings': [],
              'high_priority_count': 2,
              'estimated_score_improvement': 3.0,
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (path.endsWith('/sim/positions')) {
        return http.Response(
            jsonEncode({
              'positions': [
                {'symbol': 'TPIA', 'market': 'IDX', 'quantity': 1000.0},
              ],
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      return http.Response('not found', 404);
    });
    final repo = StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: fake,
      ),
    );

    await tester.pumpWidget(_wrap(
        RebalanceDetailPage(
            repository: repo, cache: InMemoryPortfolioInsightCache()),
        repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rebalance_action_TPIA')), findsOneWidget);
    // GGRM is not held -> the phantom EXIT is filtered out.
    expect(find.byKey(const Key('rebalance_action_GGRM')), findsNothing);
  });

  // === RebalanceReport reconcile (unit) ===================================
  test('reconciledWith drops non-held actions and recomputes counts', () {
    const report = RebalanceReport(
      actions: [
        RebalanceAction(
            symbol: 'TPIA',
            market: Market.idx,
            action: 'REDUCE',
            priority: 'HIGH'),
        RebalanceAction(
            symbol: 'GGRM',
            market: Market.idx,
            action: 'EXIT',
            priority: 'HIGH'),
      ],
      highPriorityCount: 2,
    );
    final held = report.reconciledWith({'TPIA@IDX'});
    expect(held.actions.length, 1);
    expect(held.actions.single.symbol, 'TPIA');
    expect(held.highPriorityCount, 1); // recomputed from kept actions
    expect(held.actionCount, 1);

    // Empty held set -> best-effort, leave the report untouched.
    final unchanged = report.reconciledWith(const {});
    expect(unchanged.actions.length, 2);
  });

  // === Global Rotation Engine =============================================
  testWidgets('Global Rotation card renders best market + rank table',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const GlobalRotationCard(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('global_rotation_card')), findsOneWidget);
    expect(find.byKey(const Key('global_rotation_best_market')),
        findsOneWidget);
    expect(find.text('US'), findsWidgets);
    expect(find.byKey(const Key('rotation_row_US')), findsOneWidget);
    expect(find.byKey(const Key('rotation_row_INDIA')), findsOneWidget);
    expect(find.text('OVERWEIGHT'), findsWidgets);
  });

  testWidgets('Global Rotation detail renders the full rank table',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const GlobalRotationCard(), repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('global_rotation_view_all')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('rotation_detail_list')), findsOneWidget);
    expect(find.byKey(const Key('rotation_detail_US')), findsOneWidget);
    expect(find.byKey(const Key('rotation_detail_INDIA')), findsOneWidget);
    expect(find.byKey(const Key('rotation_detail_VIETNAM')), findsOneWidget);
    expect(find.text('AVOID'), findsWidgets);
  });

  // === Dashboard integration ==============================================
  testWidgets('Dashboard shows Auto Watchlist AI + Global Rotation cards',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(
      const DashboardPage(market: Market.us),
      repo,
    ));
    await tester.pump(); // let async loads kick off
    await tester.pump(const Duration(milliseconds: 300));

    // Auto Watchlist AI is near the top.
    expect(find.byKey(const Key('auto_watchlist_section')), findsOneWidget);
    // Global Rotation is lower (after PRO Preview); scroll it into view.
    await tester.scrollUntilVisible(
      find.byKey(const Key('global_rotation_section')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('global_rotation_section')), findsOneWidget);
  });
}
