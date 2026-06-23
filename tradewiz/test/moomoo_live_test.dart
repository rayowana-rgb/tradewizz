import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/moomoo_live_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/entitlements_scope.dart';
import 'package:tradewiz/services/moomoo_secret_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

import 'package:tradewiz/pages/account_page.dart';

/// In-memory secret persistence so tests never touch the Keychain.
class _MemSecret implements MoomooSecretPersistence {
  _MemSecret([this._v]);
  String? _v;
  @override
  Future<String?> read() async => _v;
  @override
  Future<void> write(String secret) async => _v = secret;
  @override
  Future<void> clear() async => _v = null;
}

StockRepository _repoWith(MockClient client) => StockRepository(
      client: ApiClient(
        config: const AppConfig(
          baseUrl: 'https://test.tradewiz.app/v1',
          mockFallback: false,
        ),
        httpClient: client,
      ),
    );

Future<AuthStore> _auth(int uid) async {
  final auth = AuthStore();
  await auth.setSession('TOKEN',
      UserProfile(id: uid, email: 'u$uid@x.com', createdAt: '', updatedAt: ''));
  return auth;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('owner uid 2 sees the Moomoo Live entry on Account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    final repo = _repoWith(MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
        find.byKey(const Key('account_moomoo_live_link')), 200,
        scrollable: list);
    expect(find.byKey(const Key('account_moomoo_live_link')), findsOneWidget);
  });

  testWidgets('non-owner uid does NOT see the Moomoo Live entry',
      (tester) async {
    final auth = await _auth(1);
    final repo = _repoWith(MockClient((_) async => http.Response('{}', 200)));
    await tester.pumpWidget(_wrap(AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_moomoo_live_link')), findsNothing);
  });

  testWidgets('no secret -> setup card; entering secret loads account',
      (tester) async {
    final auth = await _auth(kMoomooOwnerUid);
    var accountCalls = 0;
    final repo = _repoWith(MockClient((req) async {
      if (req.url.path.endsWith('/broker/moomoo/account')) {
        accountCalls++;
        // Assert the secret header is forwarded.
        expect(req.headers['X-Moomoo-Secret'], 'topsecret');
        return http.Response(
          jsonEncode({
            'total_assets': 5000.0,
            'cash': 4000.0,
            'buying_power': 4800.0,
            'market_value': 1000.0,
            'currency': 'USD',
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/broker/moomoo/positions')) {
        return http.Response(jsonEncode({'positions': []}), 200);
      }
      return http.Response('{}', 200);
    }));

    final store = MoomooSecretStore(persistence: _MemSecret());
    await tester.pumpWidget(_wrap(
        MoomooLivePage(repository: repo, secretStore: store), auth, repo));
    await tester.pumpAndSettle();

    // No secret yet -> setup card shown, no account loaded.
    expect(find.byKey(const Key('moomoo_setup_card')), findsOneWidget);
    expect(accountCalls, 0);

    // Enter the secret via the setup dialog.
    await tester.tap(find.byKey(const Key('moomoo_setup_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('moomoo_secret_field')), 'topsecret');
    await tester.tap(find.byKey(const Key('moomoo_secret_save')));
    await tester.pumpAndSettle();

    // Account now loads (header card present, header call made).
    expect(find.byKey(const Key('moomoo_account_card')), findsOneWidget);
    expect(accountCalls, greaterThanOrEqualTo(1));
  });
}
