import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/journal_page.dart';
import 'package:tradewiz/pages/notifications_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/widgets/morning_brief.dart';
import 'package:tradewiz/widgets/notification_bell.dart';
import 'package:tradewiz/widgets/portfolio_manager.dart';

// --- Backend fixtures -------------------------------------------------------
Map<String, dynamic> _briefBody({bool cached = false}) => {
      'market': 'US',
      'title': 'AI Morning Brief',
      'generated_at': '2026-06-09T01:00:00Z',
      'session_date': '2026-06-09',
      'market_regime': 'BULL',
      'strongest_sector': 'Semiconductors',
      'headline': 'US session looks bullish. Top opportunity: NVDA (score 94).',
      'top_opportunity': {
        'symbol': 'NVDA',
        'market': 'US',
        'name': 'NVIDIA',
        'score': 94,
        'signal': 'BUY',
        'reason': 'Strong momentum, volume breakout.',
      },
      'top_multibagger': {
        'symbol': 'PLTR',
        'market': 'US',
        'name': 'Palantir',
        'score': 91,
        'signal': 'BUY',
        'reason': 'Acceleration trend + relative strength.',
      },
      'notes': ['Breadth is positive — momentum setups are favored today.'],
      'cached': cached,
    };

Map<String, dynamic> _managerBody() => {
      'user_id': 1,
      'risk_level': 'HIGH',
      'portfolio_score': 78,
      'concentration_score': 52,
      'diversification_score': 85,
      'quality_score': 80,
      'cash_pct': 4.0,
      'largest_position_pct': 63.0,
      'recommendations': [
        {
          'kind': 'concentration',
          'severity': 'critical',
          'symbol': 'TPIA',
          'title': 'High concentration',
          'message':
              'TPIA represents 63% of portfolio value. Portfolio concentration is elevated.',
        },
        {
          'kind': 'cash_allocation',
          'severity': 'warning',
          'title': 'Low cash',
          'message': 'Cash position is below 5%. Portfolio flexibility is limited.',
        },
      ],
      'simulated': true,
    };

Map<String, dynamic> _journalBody() => {
      'entries': [
        {
          'id': 2,
          'user_id': 1,
          'symbol': 'MPMX',
          'market': 'IDX',
          'buy_date': '2026-06-08T00:00:00Z',
          'buy_price': 100.0,
          'quantity': 10,
          'score': 91,
          'signal': 'BUY',
          'radar_rank': 3,
          'portfolio_health': 84,
          'status': 'OPEN',
        },
        {
          'id': 1,
          'user_id': 1,
          'symbol': 'SINI',
          'market': 'IDX',
          'buy_date': '2026-06-01T00:00:00Z',
          'buy_price': 100.0,
          'quantity': 5,
          'score': 88,
          'signal': 'BUY',
          'radar_rank': null,
          'portfolio_health': 80,
          'sell_date': '2026-06-07T00:00:00Z',
          'sell_price': 124.0,
          'realized_return': 24.0,
          'status': 'CLOSED',
        },
      ],
      'simulated': true,
    };

Map<String, dynamic> _journalStatsBody() => {
      'user_id': 1,
      'total_trades': 1,
      'open_positions': 1,
      'win_rate': 100.0,
      'average_gain': 24.0,
      'average_loss': 0.0,
      'best_trade': {
        'id': 1,
        'user_id': 1,
        'symbol': 'SINI',
        'market': 'IDX',
        'realized_return': 24.0,
        'status': 'CLOSED',
      },
      'worst_trade': {
        'id': 1,
        'user_id': 1,
        'symbol': 'SINI',
        'market': 'IDX',
        'realized_return': 24.0,
        'status': 'CLOSED',
      },
      'simulated': true,
    };

Map<String, dynamic> _notificationsBody({bool read = false}) => {
      'notifications': [
        {
          'id': 1,
          'user_id': 1,
          'notification_type': 'new_elite_opportunity',
          'title': 'New Elite Opportunity',
          'body': 'NVDA scored 94 (US) — Strong Buy.',
          'symbol': 'NVDA',
          'market': 'US',
          'created_at': '2026-06-09T01:00:00Z',
          'read': read,
        },
        {
          'id': 2,
          'user_id': 1,
          'notification_type': 'daily_pick_published',
          'title': 'Daily Picks Published',
          'body': "Today's top opportunities are ready.",
          'created_at': '2026-06-09T01:00:00Z',
          'read': read,
        },
      ],
      'unread_count': read ? 0 : 2,
    };

StockRepository _repo({
  bool briefUnavailable = false,
  List<String>? markReadCalls,
}) {
  final fake = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic>? body;
    int status = 200;
    if (path.contains('/morning-brief/')) {
      if (briefUnavailable) {
        return http.Response('{"detail":"x"}', 503,
            headers: {'content-type': 'application/json'});
      }
      body = _briefBody();
    } else if (path.endsWith('/portfolio/manager')) {
      body = _managerBody();
    } else if (path.endsWith('/journal/stats')) {
      body = _journalStatsBody();
    } else if (path.endsWith('/journal')) {
      body = _journalBody();
    } else if (path.endsWith('/notifications/read')) {
      markReadCalls?.add('read');
      body = {'user_id': 1, 'marked': 2, 'unread_count': 0};
    } else if (path.endsWith('/notifications')) {
      // Return read=true after a mark-read call was made.
      body = _notificationsBody(read: (markReadCalls?.isNotEmpty ?? false));
    }
    if (body != null) {
      return http.Response(jsonEncode(body), status,
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

AuthStore _loggedOut() => AuthStore();

Widget _wrap(Widget child, StockRepository repo, {AuthStore? auth}) {
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth ?? _loggedIn(),
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

void main() {
  // === AI Morning Brief ====================================================
  testWidgets('Morning Brief renders top opportunity + multibagger + sector',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(
        _wrap(const AiMorningBriefSection(market: Market.us), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('morning_brief_section')), findsOneWidget);
    expect(find.byKey(const Key('morning_brief_card')), findsOneWidget);
    expect(find.byKey(const Key('morning_brief_top_opportunity')),
        findsOneWidget);
    expect(find.byKey(const Key('morning_brief_top_multibagger')),
        findsOneWidget);
    expect(find.text('NVDA'), findsWidgets);
    expect(find.text('PLTR'), findsWidgets);
    expect(find.text('Semiconductors'), findsOneWidget);
    // Bullish regime chip.
    expect(find.text('Bullish'), findsOneWidget);
  });

  testWidgets('Morning Brief shows signed-out prompt when no token',
      (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(
        const AiMorningBriefSection(market: Market.us), repo,
        auth: _loggedOut()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('morning_brief_signed_out')), findsOneWidget);
  });

  testWidgets('Morning Brief shows unavailable on backend error',
      (tester) async {
    final repo = _repo(briefUnavailable: true);
    await tester.pumpWidget(
        _wrap(const AiMorningBriefSection(market: Market.us), repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('morning_brief_unavailable')), findsOneWidget);
  });

  // === AI Portfolio Manager ================================================
  testWidgets('Portfolio Manager shows risk + recommendations', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const PortfolioManagerCard(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('portfolio_manager_report')), findsOneWidget);
    expect(find.byKey(const Key('portfolio_manager_risk')), findsOneWidget);
    expect(find.text('HIGH'), findsOneWidget);
    expect(
        find.textContaining('TPIA represents 63% of portfolio value'),
        findsOneWidget);
    expect(find.byKey(const Key('pm_rec_concentration')), findsOneWidget);
    expect(find.byKey(const Key('pm_rec_cash_allocation')), findsOneWidget);
  });

  // === Portfolio Journal ===================================================
  testWidgets('Journal lists entries with snapshot + stats', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const JournalPage(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('journal_stats_card')), findsOneWidget);
    // Win rate shown (stats card is near the top).
    expect(find.text('100%'), findsWidgets);
    // Scroll the MPMX entry (below the fold in the lazy list) into view.
    await tester.scrollUntilVisible(
      find.byKey(const Key('journal_entry_MPMX')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('journal_entry_MPMX')), findsOneWidget);
    // MPMX open entry snapshot: score 91, radar rank #3.
    expect(find.textContaining('91'), findsWidgets);
    expect(find.text('#3'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('journal_entry_SINI')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('journal_entry_SINI')), findsOneWidget);
    // SINI closed with +24%.
    expect(find.textContaining('+24'), findsWidgets);
  });

  // === Notifications =======================================================
  testWidgets('Notification Center lists notifications + unread', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const NotificationCenterPage(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notifications_list')), findsOneWidget);
    expect(find.byKey(const Key('notification_1')), findsOneWidget);
    expect(find.byKey(const Key('notification_2')), findsOneWidget);
    expect(find.text('New Elite Opportunity'), findsOneWidget);
    // Unread dots present.
    expect(find.byKey(const Key('notification_unread_dot')), findsWidgets);
    expect(
        find.byKey(const Key('notifications_mark_all_read')), findsOneWidget);
  });

  testWidgets('Mark all read clears the unread state', (tester) async {
    final calls = <String>[];
    final repo = _repo(markReadCalls: calls);
    await tester.pumpWidget(_wrap(const NotificationCenterPage(), repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('notifications_mark_all_read')));
    await tester.pumpAndSettle();

    expect(calls, contains('read'));
    // After marking read the mark-all button is gone (unread == 0).
    expect(find.byKey(const Key('notifications_mark_all_read')), findsNothing);
  });

  // === Notification bell badge =============================================
  testWidgets('Notification bell shows the unread badge', (tester) async {
    final repo = _repo();
    await tester.pumpWidget(_wrap(const NotificationBell(), repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notification_bell')), findsOneWidget);
    expect(
        find.byKey(const Key('notification_unread_badge')), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });
}
