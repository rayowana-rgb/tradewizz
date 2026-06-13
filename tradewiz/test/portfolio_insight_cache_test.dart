import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/portfolio_health_cache.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/widgets/portfolio_manager.dart';
import 'package:tradewiz/widgets/rebalance.dart';

const _managerJson = {
  'risk_level': 'LOW',
  'portfolio_score': 80.0,
  'concentration_score': 70.0,
  'diversification_score': 75.0,
  'quality_score': 82.0,
  'cash_pct': 10.0,
  'largest_position_pct': 25.0,
  'recommendations': <dynamic>[],
};

const _rebalanceJson = {
  'profile': 'Balanced',
  'portfolio_score': 78.0,
  'cash_allocation': 10.0,
  'actions': <dynamic>[],
  'summary': 'Looks balanced.',
  'warnings': <dynamic>[],
  'high_priority_count': 0,
  'estimated_score_improvement': 3.0,
};

StockRepository _repo() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.contains('/portfolio/manager')) {
      return http.Response(jsonEncode(_managerJson), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.contains('/portfolio/rebalance')) {
      return http.Response(jsonEncode(_rebalanceJson), 200,
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
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
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
  testWidgets('AI Portfolio Manager: fetch persists to cache; reopen has no '
      'spinner', (tester) async {
    final auth = await _auth();
    final repo = _repo();
    final cache = InMemoryPortfolioInsightCache();

    // First open: fetches and persists.
    await tester.pumpWidget(
        _wrap(PortfolioManagerCard(repository: repo, cache: cache), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('portfolio_manager_report')), findsOneWidget);
    final cached =
        await cache.read(PortfolioInsightFeature.manager, 'TOKEN');
    expect(cached, isNotNull);
    expect(cached!['risk_level'], 'LOW');

    // Reopen with a seeded cache: report shows on first frames, no spinner.
    final seeded = InMemoryPortfolioInsightCache();
    await seeded.write(PortfolioInsightFeature.manager, 'TOKEN',
        Map<String, dynamic>.from(_managerJson));
    await tester.pumpWidget(_wrap(
        PortfolioManagerCard(repository: repo, cache: seeded), auth, repo));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('portfolio_manager_report')), findsOneWidget);
    expect(find.byKey(const Key('portfolio_manager_loading')), findsNothing);
    await tester.pumpAndSettle();
  });

  testWidgets('Portfolio Rebalancing: fetch persists to cache; reopen has no '
      'spinner', (tester) async {
    final auth = await _auth();
    final repo = _repo();
    final cache = InMemoryPortfolioInsightCache();

    await tester.pumpWidget(
        _wrap(RebalanceCard(repository: repo, cache: cache), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rebalance_card')), findsOneWidget);
    final cached =
        await cache.read(PortfolioInsightFeature.rebalance, 'TOKEN');
    expect(cached, isNotNull);
    expect(cached!['profile'], 'Balanced');

    final seeded = InMemoryPortfolioInsightCache();
    await seeded.write(PortfolioInsightFeature.rebalance, 'TOKEN',
        Map<String, dynamic>.from(_rebalanceJson));
    await tester.pumpWidget(
        _wrap(RebalanceCard(repository: repo, cache: seeded), auth, repo));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('rebalance_card')), findsOneWidget);
    expect(find.byKey(const Key('rebalance_loading')), findsNothing);
    await tester.pumpAndSettle();
  });
}
