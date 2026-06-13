import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/portfolio_health_cache.dart';
import 'package:tradewiz/services/repository_scope.dart';

const _healthJson = {
  'health_score': 78.0,
  'rating': 'Healthy',
  'components': <String, dynamic>{},
  'warnings': <String>[],
  'strengths': <String>['Diversified across sectors.'],
  'exit_warnings': <String>[],
  'positions': <dynamic>[],
};

StockRepository _repo() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': {
            'cash': 90000.0,
            'equity': 150000.0,
            'buying_power': 90000.0,
            'market_value': 60000.0,
            'unrealized_pnl': 1200.0,
            'realized_pnl': 0.0,
            'currency': 'USD',
            'simulated': true,
            'disclaimer': 'Simulated.',
          },
          'positions': const [],
          'simulated': true,
          'disclaimer': 'Simulated.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/trades')) {
      return http.Response(jsonEncode({'trades': [], 'simulated': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.contains('/portfolio/health')) {
      return http.Response(jsonEncode(_healthJson), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response(jsonEncode({}), 200,
        headers: {'content-type': 'application/json'});
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: fake,
    ),
  );
}

Widget _wrap(Widget child, AuthStore auth, StockRepository repo) {
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth,
      child: EntitlementsScope(
        store: EntitlementsStore(repository: repo),
        child: MaterialApp(home: Scaffold(body: child)),
      ),
    ),
  );
}

Future<AuthStore> _auth() async {
  final auth = AuthStore();
  await auth.setSession('TOKEN',
      const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return auth;
}

void main() {
  testWidgets('first open fetches health and writes it to the cache',
      (tester) async {
    final auth = await _auth();
    final repo = _repo();
    final cache = InMemoryPortfolioHealthCache();

    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, healthCache: cache), auth, repo));
    await tester.pumpAndSettle();

    // Health card (below the fold) shows the fetched score.
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_health_card')), 120,
        scrollable: list);
    expect(find.byKey(const Key('account_health_score')), findsOneWidget);
    expect(find.text('78'), findsOneWidget);

    // The fetched health was persisted to the cache for next time.
    final cached = await cache.read('TOKEN');
    expect(cached, isNotNull);
    expect(cached!['rating'], 'Healthy');
  });

  testWidgets('reopening renders cached health immediately (no spinner)',
      (tester) async {
    final auth = await _auth();
    final repo = _repo();
    // Pre-seed the cache as if a previous session had saved it.
    final cache = InMemoryPortfolioHealthCache();
    await cache.write('TOKEN', Map<String, dynamic>.from(_healthJson));

    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, healthCache: cache), auth, repo));
    // Let the synchronous cache seed run (microtask), but do NOT settle the
    // network: the cached health should already be available.
    await tester.pump();
    await tester.pump();

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_health_card')), 120,
        scrollable: list);
    expect(find.byKey(const Key('account_health_score')), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    // No spinner inside the health card while cached data is shown.
    expect(
        find.descendant(
            of: find.byKey(const Key('account_health_card')),
            matching: find.byType(CircularProgressIndicator)),
        findsNothing);

    await tester.pumpAndSettle();
    expect(find.text('78'), findsOneWidget);
  });
}
