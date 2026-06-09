import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/pages/home_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
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

StockRepository _repo({
  bool indexAvailable = true,
  String condition = 'GREED',
  double? valueTraded = 3.4e12,
}) {
  final fake = MockClient((req) async {
    final path = req.url.path;
    Map<String, dynamic> json(Object o) => o as Map<String, dynamic>;
    if (path.endsWith('/market/indices')) {
      return http.Response(
        jsonEncode({
          'indices': [
            {
              'symbol': '^JKSE',
              'market': 'IDX',
              'name': 'IHSG',
              'currency': 'IDR',
              'status': 'CLOSED',
              'available': indexAvailable,
              'price': indexAvailable ? 7250.5 : null,
              'change': indexAvailable ? 35.2 : null,
              'change_percent': indexAvailable ? 0.49 : null,
              'updated_at': '2026-06-10T08:00:00Z',
            }
          ]
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/market/condition')) {
      return http.Response(
        jsonEncode({
          'condition': condition,
          'condition_score': 72,
          'reason': 'Index above its short-term average with momentum.',
          'market': 'IDX',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.contains('/market/overview')) {
      return http.Response(
        jsonEncode({
          'market': 'IDX',
          'total_value_traded': valueTraded,
          'advancers': 200,
          'decliners': 100,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': {
            'cash': 1.0,
            'equity': 1.0,
            'buying_power': 1.0,
            'market_value': 0.0,
            'unrealized_pnl': 0.0,
            'realized_pnl': 0.0,
            'currency': 'IDR',
            'simulated': true,
            'disclaimer': 'Simulated.',
          },
          'positions': [],
          'simulated': true,
          'disclaimer': 'Simulated.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    json; // silence unused
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

Future<void> _pumpHome(WidgetTester tester, StockRepository repo) async {
  final cache = CacheService.inMemory();
  // Seed a minimal dashboard so Home renders instantly with a brief.
  await cache.write(SnapshotKeys.dashboard(Market.idx), {
    'generated_at': '2026-06-10T08:00:00Z',
    'market': 'IDX',
    'morning_brief': {
      'market': 'IDX',
      'headline': 'IDX strong.',
      'strongest_sector': 'Banking',
      'notes': ['Note one'],
    },
  }, ttl: SnapshotKeys.dashboardTtl);
  final snap = SnapshotRepository(repo, cache: cache);
  final prefs = UserPrefsStore(
      persistence: _MemPrefs(const UserPrefs(onboarded: true)));
  await prefs.load();
  final auth = AuthStore();
  await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AuthScope(
          store: auth,
          child: WatchlistScope(
            store: WatchlistStore(),
            child: UserPrefsScope(
              store: prefs,
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
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Home shows the index movement card with price + change',
      (tester) async {
    await _pumpHome(tester, _repo());

    final list = find.byKey(const Key('home_list'));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
        find.byKey(const Key('home_index_card')), 300,
        scrollable: scrollable);

    expect(find.byKey(const Key('home_index_card')), findsOneWidget);
    expect(find.byKey(const Key('home_index_name')), findsOneWidget);
    expect(find.text('IHSG'), findsOneWidget);
    expect(find.byKey(const Key('home_index_price')), findsOneWidget);
    expect(find.byKey(const Key('home_index_change')), findsOneWidget);
  });

  testWidgets('Home shows market condition (Fear/Greed) and value traded',
      (tester) async {
    await _pumpHome(tester, _repo(condition: 'GREED'));

    final list = find.byKey(const Key('home_list'));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
        find.byKey(const Key('home_condition_badge')), 300,
        scrollable: scrollable);

    expect(find.byKey(const Key('home_condition_badge')), findsOneWidget);
    expect(find.text('Greed'), findsOneWidget);
    // Value traded formatted as compact Rupiah.
    expect(find.byKey(const Key('home_value_traded')), findsOneWidget);
    expect(find.text('Rp3.4T'), findsOneWidget);
  });

  testWidgets('Home renders the index card even when index data is missing',
      (tester) async {
    await _pumpHome(tester, _repo(indexAvailable: false, valueTraded: null));

    final list = find.byKey(const Key('home_list'));
    final scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(
        find.byKey(const Key('home_index_card')), 300,
        scrollable: scrollable);

    // Card still present; shows an unavailable state instead of disappearing.
    expect(find.byKey(const Key('home_index_card')), findsOneWidget);
    expect(find.byKey(const Key('home_index_unavailable')), findsOneWidget);
  });
}
