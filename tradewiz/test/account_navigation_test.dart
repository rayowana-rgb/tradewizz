import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
import 'package:tradewiz/pages/advanced_page.dart';
import 'package:tradewiz/pages/journal_page.dart';
import 'package:tradewiz/pages/portfolio_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/repository_scope.dart';

/// Account repo: simulated portfolio + empty journal/broker so we can exercise
/// both the navigation IA and the mature empty states.
StockRepository _repo() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/sim/portfolio')) {
      return http.Response(
        jsonEncode({
          'account': {
            'cash': 100000.0,
            'equity': 100000.0,
            'buying_power': 100000.0,
            'market_value': 0.0,
            'unrealized_pnl': 0.0,
            'realized_pnl': 0.0,
            'currency': 'USD',
            'simulated': true,
            'disclaimer': 'Simulated.',
          },
          'positions': <Map<String, dynamic>>[],
          'simulated': true,
          'disclaimer': 'Simulated.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.endsWith('/sim/trades')) {
      return http.Response(
          jsonEncode({'trades': [], 'simulated': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.endsWith('/journal/stats')) {
      return http.Response(
          jsonEncode({
            'total_trades': 0,
            'open_positions': 0,
            'win_rate': 0,
            'average_gain': 0,
            'average_loss': 0,
          }),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path.endsWith('/journal')) {
      return http.Response(jsonEncode({'entries': []}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.contains('/portfolio/health')) {
      return http.Response(jsonEncode({}), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path.endsWith('/portfolio')) {
      // No brokers connected -> mature empty state.
      return http.Response(
          jsonEncode({
            'summary': {},
            'positions': [],
            'brokers': <String>[],
            'errors': [],
          }),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path.contains('/portfolio/performance')) {
      return http.Response(jsonEncode({}), 200,
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

Widget _wrapAccount(Widget child, AuthStore auth, StockRepository repo) {
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

Widget _wrapSimple(Widget child, StockRepository repo, {bool loggedIn = true}) {
  final auth = AuthStore();
  if (loggedIn) {
    auth.setSession('TOKEN', const UserProfile(
        id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  }
  return RepositoryScope(
    repository: repo,
    child: AuthScope(
      store: auth,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

Future<void> _pumpAccount(WidgetTester tester, StockRepository repo) async {
  final auth = AuthStore();
  await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  await tester.pumpWidget(_wrapAccount(AccountPage(repository: repo), auth, repo));
  await tester.pumpAndSettle();
}

void main() {
  // ----- Account navigation: no duplicates, single entries -----------------

  testWidgets('Account shows exactly one Trade Journal entry', (tester) async {
    await _pumpAccount(tester, _repo());
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_journal_link')), 300, scrollable: list);
    expect(find.byKey(const Key('account_journal_link')), findsOneWidget);
    expect(find.text('Trade Journal'), findsOneWidget);
  });

  testWidgets('Account shows exactly one Connected Brokers entry',
      (tester) async {
    await _pumpAccount(tester, _repo());
    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_brokers_portfolio_link')), 300,
        scrollable: list);
    expect(
        find.byKey(const Key('account_brokers_portfolio_link')), findsOneWidget);
    expect(find.text('Connected Brokers'), findsOneWidget);
  });

  testWidgets('Account shows the four section headers', (tester) async {
    final repo = _repo();
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
        id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    await tester
        .pumpWidget(_wrapAccount(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    const headers = <String, String>{
      'account_section_portfolio': 'PORTFOLIO',
      'account_section_insights': 'INSIGHTS',
      'account_section_connections': 'CONNECTIONS',
      'account_section_account': 'ACCOUNT',
    };
    for (final entry in headers.entries) {
      await tester.scrollUntilVisible(find.byKey(Key(entry.key)), 300,
          scrollable: list);
      expect(find.byKey(Key(entry.key)), findsOneWidget,
          reason: 'expected section header "${entry.key}"');
      // The visible label is present while the header is on-screen.
      expect(find.text(entry.value), findsOneWidget,
          reason: 'expected visible label "${entry.value}"');
    }
  });

  // ----- Advanced page: only advanced/debug tools, no user-facing dups -----

  testWidgets('Advanced page has no Trade Journal and no Connected Broker',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdvancedPage()));
    await tester.pumpAndSettle();

    expect(find.text('Advanced Tools'), findsWidgets);
    expect(find.byKey(const Key('advanced_description')), findsOneWidget);

    // Journal / Portfolio Journal must NOT appear here (lives in Account).
    expect(find.textContaining('Journal'), findsNothing);
    expect(find.textContaining('Connected Broker'), findsNothing);

    // Only advanced/debug tools.
    expect(find.byKey(const Key('advanced_global_rotation')), findsOneWidget);
    expect(find.byKey(const Key('advanced_cache_inspector')), findsOneWidget);
    expect(find.byKey(const Key('advanced_snapshot_inspector')), findsOneWidget);
    expect(find.byKey(const Key('advanced_analytics')), findsOneWidget);

    // Debug-only tools are labelled so they don't look like investing features.
    expect(find.text('Developer Tool'), findsWidgets);
  });

  // ----- Mature empty states ----------------------------------------------

  testWidgets('Empty Journal shows mature empty state with CTA',
      (tester) async {
    await tester.pumpWidget(_wrapSimple(JournalPage(repository: _repo()),
        _repo()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('journal_empty')), findsOneWidget);
    expect(find.text('No trades yet'), findsOneWidget);
    expect(find.textContaining('simulated buy/sell orders'), findsOneWidget);
    expect(find.byKey(const Key('journal_empty_cta')), findsOneWidget);
  });

  testWidgets('Connected Broker empty state shows mature message',
      (tester) async {
    await tester.pumpWidget(_wrapSimple(PortfolioPage(repository: _repo()),
        _repo()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('broker_empty')), findsOneWidget);
    expect(
        find.text('Broker connection is not enabled yet'), findsOneWidget);
    expect(find.textContaining('simulated portfolio tracking'), findsOneWidget);
    expect(find.byKey(const Key('broker_empty_cta')), findsOneWidget);
    expect(find.textContaining('coming soon'), findsOneWidget);
  });
}
