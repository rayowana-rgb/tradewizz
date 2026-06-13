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
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/theme_tradewizz.dart';

StockRepository _repo() {
  final client = MockClient((req) async {
    if (req.url.path.endsWith('/sim/portfolio')) {
      return _json({
        'account': {
          'cash': 998000.0,
          'equity': 1000200.0,
          'buying_power': 998000.0,
          'currency': 'USD',
        },
        'positions': [
          {
            'symbol': 'AAPL',
            'market': 'US',
            'qty': 10,
            'avg_price': 100.0,
            'last_price': 120.0,
            'market_value': 1200.0,
            'unrealized_pl': 200.0,
            'unrealized_pl_pct': 0.2,
            'currency': 'USD',
          }
        ],
        'trades': [
          {
            'id': 't1',
            'symbol': 'AAPL',
            'market': 'US',
            'side': 'BUY',
            'qty': 10,
            'price': 100.0,
            'ts': '2026-06-12T10:00:00Z',
            'currency': 'USD',
          }
        ],
      });
    }
    return _json({});
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://t/v1', mockFallback: true),
      httpClient: client,
    ),
  );
}

http.Response _json(Object o) =>
    http.Response(jsonEncode(o), 200, headers: {'content-type': 'application/json'});

AuthStore _loggedIn() {
  final s = AuthStore();
  s.setSession('JWT',
      const UserProfile(id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
  return s;
}

// Regression: tapping "Open portfolio" on Home pushed AccountPage as a bare
// route (no Theme/Scaffold/SafeArea), which left it without width constraints
// or a Material ancestor -> a ~100k px RenderFlex overflow (the yellow/black
// stripes the user reported). Home now wraps it in a themed Scaffold; the
// stat rows + Early Access header were also hardened against overflow on
// narrow phones. This test pushes AccountPage on a small screen and asserts
// no exception (no overflow) is thrown.
void main() {
  testWidgets('Open portfolio (pushed from Home) has no overflow', (tester) async {
    // Narrow phone (360x800 logical) where wide money strings used to overflow.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final repo = _repo();
    final store = _loggedIn();
    await tester.pumpWidget(MaterialApp(
      // Scopes wrap EVERY route (like main.dart), so pushed routes keep them.
      builder: (context, child) => RepositoryScope(
        repository: repo,
        child: AuthScope(store: store, child: child!),
      ),
      home: Builder(builder: (context) {
        return Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => Theme(
                    data: buildTradeWizzTheme(),
                    child: Scaffold(
                      backgroundColor: TWColors.bgBase,
                      appBar: AppBar(title: Text('Account', style: TWType.title3)),
                      body: SafeArea(
                        bottom: false,
                        child: AccountPage(repository: repo),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('Open portfolio'),
            ),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open portfolio'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
