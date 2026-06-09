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
    expect(find.text('BBCA'), findsWidgets);
    expect(find.text('92'), findsWidgets); // confidence
    expect(
        find.text('Strong momentum and accumulation detected.'), findsWidgets);
    expect(find.byKey(const Key('home_hero_cta')), findsOneWidget);

    // 3-bullet brief.
    expect(find.byKey(const Key('home_brief')), findsOneWidget);
    expect(find.text('15s read'), findsOneWidget);

    // Portfolio-first card present (above the fold under the brief).
    expect(find.byKey(const Key('home_portfolio')), findsOneWidget);
    expect(find.byKey(const Key('home_watchlist')), findsOneWidget);

    // Today's Ideas merged feed (scroll the list to reach it).
    final list = find.byKey(const Key('home_list'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('home_idea_TLKM')),
      300,
      scrollable: find.descendant(
          of: list, matching: find.byType(Scrollable)),
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
}
