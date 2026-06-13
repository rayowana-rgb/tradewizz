import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/journal_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/portfolio_health_cache.dart';
import 'package:tradewiz/services/repository_scope.dart';

// The Portfolio / Trade Journal page caches its entries + stats
// (stale-while-revalidate): on open it renders the last known data instantly
// from the local cache, then revalidates in the background and writes the fresh
// result back to the cache.
void main() {
  // Repo whose journal endpoints either return a fresh entry or fail (503),
  // so we can exercise both the write-back and the keep-cached paths.
  StockRepository repoWith({Map<String, dynamic>? entry, bool fail = false}) {
    final fake = MockClient((req) async {
      final p = req.url.path;
      if (fail && (p.endsWith('/journal') || p.endsWith('/journal/stats'))) {
        return http.Response('{"detail":"down"}', 503,
            headers: {'content-type': 'application/json'});
      }
      if (p.endsWith('/journal/stats')) {
        return http.Response(
            jsonEncode({
              'total_trades': 5,
              'win_rate': 80.0,
              'open_positions': 2,
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      if (p.endsWith('/journal')) {
        return http.Response(
            jsonEncode({
              'entries': [entry]
            }),
            200,
            headers: {'content-type': 'application/json'});
      }
      // Manager card fails -> irrelevant to this test.
      return http.Response('{"detail":"x"}', 503,
          headers: {'content-type': 'application/json'});
    });
    return StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.app/v1'),
        httpClient: fake,
      ),
    );
  }

  Widget wrap(StockRepository repo, PortfolioInsightCache cache) {
    final auth = AuthStore()
      ..setSession('JWT',
          const UserProfile(
              id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    return RepositoryScope(
      repository: repo,
      child: AuthScope(
        store: auth,
        child: MaterialApp(
          home: JournalPage(repository: repo, journalCache: cache),
        ),
      ),
    );
  }

  Map<String, dynamic> cachedBundle(String symbol) => {
        'entries': [
          {
            'symbol': symbol,
            'market': 'IDX',
            'score': 70,
            'signal': 'BUY',
            'status': 'OPEN',
          }
        ],
        'stats': {'total_trades': 1, 'win_rate': 50.0},
      };

  testWidgets('renders cached entry when the network is down (keep-cached)',
      (t) async {
    final cache = InMemoryPortfolioInsightCache();
    await cache.write(
        PortfolioInsightFeature.journal, 'JWT', cachedBundle('CACHED'));

    // Network fails -> the page must fall back to the cached entry, not error.
    final repo = repoWith(fail: true);

    await t.pumpWidget(wrap(repo, cache));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('journal_entry_CACHED')), findsOneWidget);
    // No error empty-state when cached data is available.
    expect(find.byKey(const Key('journal_empty')), findsNothing);
  });

  testWidgets('writes fresh network result back to the cache', (t) async {
    final cache = InMemoryPortfolioInsightCache();
    final repo = repoWith(entry: {
      'symbol': 'FRESH',
      'market': 'IDX',
      'score': 88,
      'signal': 'STRONG BUY',
      'status': 'OPEN',
    });

    await t.pumpWidget(wrap(repo, cache));
    await t.pumpAndSettle();

    expect(find.byKey(const Key('journal_entry_FRESH')), findsOneWidget);

    final saved =
        await cache.read(PortfolioInsightFeature.journal, 'JWT');
    expect(saved, isNotNull);
    final entries = saved!['entries'] as List<dynamic>;
    expect((entries.first as Map)['symbol'], 'FRESH');
  });
}
