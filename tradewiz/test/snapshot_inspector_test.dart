import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/snapshot_inspector_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/snapshot/snapshot_keys.dart';
import 'package:tradewiz/snapshot/snapshot_repository.dart';

AuthStore _loggedIn() {
  final s = AuthStore();
  s.setSession('JWT',
      const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return s;
}

void main() {
  testWidgets('Snapshot Inspector lists snapshots, ages and metrics',
      (tester) async {
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us),
        {'market': 'US', 'rotation': {'best_market': 'US'}},
        ttl: SnapshotKeys.dashboardTtl);

    final repo = SnapshotRepository(
      StockRepository(
        client: ApiClient(
          config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
          httpClient: MockClient((_) async => http.Response('x', 500)),
        ),
      ),
      cache: cache,
    );

    await tester.pumpWidget(MaterialApp(
      home: AuthScope(
        store: _loggedIn(),
        child: SnapshotInspectorPage(
          service: cache,
          repository: repo,
          market: Market.us,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('snapshot_inspector_list')), findsOneWidget);
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Portfolio'), findsWidgets);
    expect(find.text('Watchlist'), findsWidgets);
    expect(find.byKey(const Key('snapshot_metrics')), findsOneWidget);
  });

  testWidgets('Clear Snapshots removes stored snapshots', (tester) async {
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us), {'market': 'US'},
        ttl: SnapshotKeys.dashboardTtl);
    await cache.write(SnapshotKeys.portfolio, {'account': {}},
        ttl: SnapshotKeys.portfolioTtl);

    final repo = SnapshotRepository(
      StockRepository(
        client: ApiClient(
          config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
          httpClient: MockClient((_) async => http.Response('x', 500)),
        ),
      ),
      cache: cache,
    );

    await tester.pumpWidget(MaterialApp(
      home: AuthScope(
        store: _loggedIn(),
        child: SnapshotInspectorPage(
          service: cache,
          repository: repo,
          market: Market.us,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(cache.has(SnapshotKeys.dashboard(Market.us)), isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const Key('snapshot_clear_all')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('snapshot_clear_all')));
    await tester.pumpAndSettle();
    expect(cache.has(SnapshotKeys.dashboard(Market.us)), isFalse);
    expect(cache.has(SnapshotKeys.portfolio), isFalse);
  });
}
