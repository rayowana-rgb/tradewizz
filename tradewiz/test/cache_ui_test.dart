import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_keys.dart';
import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/cache/cached_repository.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/cache_inspector_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/widgets/morning_brief.dart';

StockRepository _briefRepo() {
  final fake = MockClient((req) async {
    if (req.url.path.contains('/morning-brief/')) {
      return http.Response(
        jsonEncode({
          'market': 'US',
          'title': 'AI Morning Brief',
          'market_regime': 'BULL',
          'strongest_sector': 'Tech',
          'headline': 'Live headline',
          'notes': const [],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('nf', 404);
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

Widget _wrap(Widget child, StockRepository repo, CacheService cache) {
  return RepositoryScope(
    repository: repo,
    cached: CachedRepository(repo, cache: cache),
    child: AuthScope(
      store: _loggedIn(),
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

void main() {
  testWidgets('Morning Brief shows a freshness status line after loading',
      (tester) async {
    final cache = CacheService.inMemory();
    await tester.pumpWidget(
        _wrap(const AiMorningBriefSection(market: Market.us),
            _briefRepo(), cache));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('morning_brief_card')), findsOneWidget);
    // SWR rendered fresh data -> "Updated ... ago".
    expect(find.byKey(const Key('cache_status_line')), findsOneWidget);
    expect(find.textContaining('Updated'), findsWidgets);
  });

  testWidgets('Morning Brief renders cached data first (no blank screen) '
      'when offline', (tester) async {
    final cache = CacheService.inMemory();
    // Pre-seed the cache, then point the repo at a dead backend.
    await cache.write(CacheKeys.morningBrief(Market.us), {
      'market': 'US',
      'market_regime': 'BULL',
      'strongest_sector': 'Energy',
      'headline': 'Cached headline',
      'notes': const [],
    }, ttl: CacheKeys.ttlMorningBrief);

    final deadRepo = StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((_) async => http.Response('down', 500)),
      ),
    );

    await tester.pumpWidget(
        _wrap(const AiMorningBriefSection(market: Market.us),
            deadRepo, cache));
    await tester.pumpAndSettle();

    // Cached brief is shown; never the "unavailable" state.
    expect(find.byKey(const Key('morning_brief_card')), findsOneWidget);
    expect(find.text('Cached headline'), findsOneWidget);
    expect(find.byKey(const Key('morning_brief_unavailable')), findsNothing);
  });

  testWidgets('Cache Inspector lists entries and clears them', (tester) async {
    final cache = CacheService.inMemory();
    await cache.write(CacheKeys.globalRotation, {'best_market': 'US'},
        ttl: CacheKeys.ttlGlobalRotation);
    await cache.write(CacheKeys.indices, {'indices': const []},
        ttl: CacheKeys.ttlIndices);

    await tester.pumpWidget(MaterialApp(
      home: CacheInspectorPage(service: cache),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cache_inspector_list')), findsOneWidget);
    expect(find.text('Rotation'), findsOneWidget);
    expect(find.text('Indices'), findsOneWidget);

    // Clear one.
    await tester.tap(find.byKey(Key('cache_clear_${CacheKeys.indices}')));
    await tester.pumpAndSettle();
    expect(find.text('Indices'), findsNothing);
    expect(find.text('Rotation'), findsOneWidget);

    // Clear all.
    await tester.tap(find.byKey(const Key('cache_inspector_clear_all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cache_inspector_empty')), findsOneWidget);
  });
}
