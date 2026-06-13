import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/home/activation_metrics.dart';
import 'package:tradewiz/home/activation_scope.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/pages/home_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/services/user_prefs_scope.dart';
import 'package:tradewiz/services/user_prefs_store.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';
import 'package:tradewiz/snapshot/snapshot_keys.dart';
import 'package:tradewiz/snapshot/snapshot_repository.dart';

class _MemPrefs implements UserPrefsPersistence {
  _MemPrefs(this.value);
  UserPrefs? value;
  @override
  Future<UserPrefs?> load() async => value;
  @override
  Future<void> save(UserPrefs v) async => value = v;
}

Map<String, dynamic> _dashboard() => {
      'generated_at': '2026-06-09T08:00:00Z',
      'market': 'IDX',
      'morning_brief': {
        'market': 'IDX',
        'headline': 'IDX is strong today.',
        'strongest_sector': 'Banking',
        'top_opportunity': {
          'symbol': 'BBCA',
          'market': 'IDX',
          'name': 'Bank Central Asia',
          'score': 92,
          'signal': 'BUY',
          'reason': 'Strong momentum and accumulation detected.',
        },
        'notes': ['US market remains strongest'],
      },
      'daily_picks': {
        'title': 't',
        'date': 'd',
        'picks': [
          {
            'rank': 1,
            'symbol': 'BBCA',
            'market': 'IDX',
            'name': 'Bank Central Asia',
            'score': 92,
            'signal': 'BUY',
            'recommendation': 'Strong momentum and accumulation detected.',
          },
          {
            'rank': 2,
            'symbol': 'TLKM',
            'market': 'IDX',
            'name': 'Telkom',
            'score': 81,
            'signal': 'WATCH',
            'recommendation': 'Approaching breakout.',
          },
        ],
      },
    };

void main() {
  testWidgets('Home renders hero, 3-bullet brief and Today\'s Ideas',
      (tester) async {
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.idx), _dashboard(),
        ttl: SnapshotKeys.dashboardTtl);

    final repo = StockRepository();
    final snap = SnapshotRepository(repo, cache: cache);
    final prefs = UserPrefsStore(
      persistence: _MemPrefs(
          const UserPrefs(onboarded: true, displayName: 'Bayu')),
    );
    await prefs.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthScope(
            store: AuthStore(), // no token -> no network
            child: WatchlistScope(
              store: WatchlistStore(),
              child: UserPrefsScope(
                store: prefs,
                child: ActivationScope(
                  metrics: ActivationMetrics(),
                  child: RepositoryScope(
                    repository: repo,
                    snapshot: snap,
                    child: const HomePage(market: Market.idx),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Hero: greeting + best idea + confidence + reason + CTA.
    expect(find.byKey(const Key('home_hero')), findsOneWidget);
    // Greeting includes the user's name (time-of-day prefix varies).
    expect(find.textContaining('Bayu'), findsWidgets);
    expect(find.text("Today's Best Idea"), findsOneWidget);
    // Best idea now shows the FULL company name (truncated only when it does
    // not fit), with the ticker as a subtitle.
    expect(find.byKey(const Key('home_hero_name')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('home_hero_name')))
          .data,
      'Bank Central Asia',
    );
    expect(find.text('BBCA'), findsWidgets); // ticker subtitle
    expect(find.text('92'), findsWidgets); // confidence
    // The old "Score N" pill was removed from the HERO; only Confidence
    // remains there. (Other surfaces like Today's Ideas may still show a score.)
    expect(
      find.descendant(
        of: find.byKey(const Key('home_hero')),
        matching: find.textContaining('Score '),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('home_hero')),
        matching: find.text('Confidence'),
      ),
      findsOneWidget,
    );
    expect(
        find.text('Strong momentum and accumulation detected.'), findsWidgets);
    expect(find.byKey(const Key('home_hero_cta')), findsOneWidget);

    // 3-bullet brief.
    expect(find.byKey(const Key('home_brief')), findsOneWidget);
    expect(find.text('15s read'), findsOneWidget);

    // Index movement card present (Phase C) just under the brief.
    expect(find.byKey(const Key('home_index_card')), findsOneWidget);

    // Portfolio + watchlist + ideas live further down: scroll to reach them.
    final list = find.byKey(const Key('home_list'));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
      find.byKey(const Key('home_portfolio')),
      300,
      scrollable: scrollable,
    );
    expect(find.byKey(const Key('home_portfolio')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('home_idea_TLKM')),
      300,
      scrollable: scrollable,
    );
    expect(find.byKey(const Key('home_idea_TLKM')), findsOneWidget);
  });

  testWidgets('Home shows a graceful empty hero when no snapshot exists',
      (tester) async {
    final cache = CacheService.inMemory();
    final repo = StockRepository();
    final snap = SnapshotRepository(repo, cache: cache);
    final prefs = UserPrefsStore(
      persistence: _MemPrefs(const UserPrefs(onboarded: true)),
    );
    await prefs.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthScope(
            store: AuthStore(),
            child: WatchlistScope(
              store: WatchlistStore(),
              child: UserPrefsScope(
                store: prefs,
                child: ActivationScope(
                  metrics: ActivationMetrics(),
                  child: RepositoryScope(
                    repository: repo,
                    snapshot: snap,
                    child: const HomePage(market: Market.idx),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home_hero')), findsOneWidget);
    // No CTA when there is no idea yet.
    expect(find.byKey(const Key('home_hero_cta')), findsNothing);
  });

  testWidgets('Today\'s Ideas shows the best index (Global Rotation) ABOVE '
      'the best stock', (tester) async {
    final dash = _dashboard();
    // Add Global Rotation data: US is the top-ranked market today.
    dash['rotation'] = {
      'generated_at': '2026-06-09T08:00:00Z',
      'session_date': '2026-06-09',
      'best_market': 'US',
      'rotation_summary': 'US leads global rotation.',
      'markets': [
        {
          'market': 'US',
          'rotation_score': 88.0,
          'rank': 1,
          'regime': 'BULL',
          'recommendation': 'OVERWEIGHT',
        },
        {
          'market': 'IDX',
          'rotation_score': 64.0,
          'rank': 2,
          'regime': 'NEUTRAL',
          'recommendation': 'NEUTRAL',
        },
      ],
    };

    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.idx), dash,
        ttl: SnapshotKeys.dashboardTtl);

    final repo = StockRepository();
    final snap = SnapshotRepository(repo, cache: cache);
    final prefs = UserPrefsStore(
      persistence: _MemPrefs(const UserPrefs(onboarded: true)),
    );
    await prefs.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AuthScope(
            store: AuthStore(),
            child: WatchlistScope(
              store: WatchlistStore(),
              child: UserPrefsScope(
                store: prefs,
                child: ActivationScope(
                  metrics: ActivationMetrics(),
                  child: RepositoryScope(
                    repository: repo,
                    snapshot: snap,
                    child: const HomePage(market: Market.idx),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final list = find.byKey(const Key('home_list'));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
      find.byKey(const Key('home_best_index')),
      300,
      scrollable: scrollable,
    );

    // The best-index card exists and names the top-ranked market (US).
    expect(find.byKey(const Key('home_best_index')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('home_best_index')),
        matching: find.text('Best Index'),
      ),
      findsOneWidget,
    );

    // It sits ABOVE the first best-stock idea: index card's top < stock's top.
    final indexTop =
        tester.getTopLeft(find.byKey(const Key('home_best_index'))).dy;
    final firstStockTop =
        tester.getTopLeft(find.byKey(const Key('home_idea_BBCA'))).dy;
    expect(indexTop, lessThan(firstStockTop));
  });
}
