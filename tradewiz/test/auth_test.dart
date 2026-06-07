import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/account_page.dart';
import 'package:tradewiz/pages/auth_pages.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';

/// Fake auth backend: register/login succeed for the right password; login with
/// a wrong password returns 401 with a detail message.
StockRepository _authRepo() {
  final fake = MockClient((req) async {
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;
    Map<String, dynamic> userJson(String email) => {
          'id': 1,
          'email': email,
          'created_at': '2026-06-07T00:00:00Z',
          'updated_at': '2026-06-07T00:00:00Z',
          'connected_brokers': 0,
        };
    if (req.url.path.endsWith('/auth/register') ||
        req.url.path.endsWith('/auth/login')) {
      if (req.url.path.endsWith('/auth/login') &&
          body['password'] != 'password123') {
        return http.Response(
          jsonEncode({'detail': 'Invalid email or password.'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'access_token': 'TOKEN-ABC',
          'token_type': 'bearer',
          'user': userJson(body['email'] as String),
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path.endsWith('/auth/logout')) {
      return http.Response(jsonEncode({'success': true}), 200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('not found', 404);
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
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

void main() {
  test('AuthStore persists and clears session', () async {
    final store = AuthStore();
    expect(store.isLoggedIn, isFalse);
    await store.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    expect(store.isLoggedIn, isTrue);
    expect(store.user!.email, 'a@b.com');
    await store.clear();
    expect(store.isLoggedIn, isFalse);
  });

  testWidgets('Login page logs in and stores the session', (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(LoginPage(repository: repo), auth, repo));

    await tester.enterText(find.byKey(const Key('email_field')), 'a@b.com');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'password123');
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isTrue);
    expect(auth.token, 'TOKEN-ABC');
    expect(auth.user!.email, 'a@b.com');
  });

  testWidgets('Login with wrong password shows an error, no session',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(LoginPage(repository: repo), auth, repo));

    await tester.enterText(find.byKey(const Key('email_field')), 'a@b.com');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'wrongpass');
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
    expect(find.byKey(const Key('auth_error')), findsOneWidget);
    expect(find.textContaining('Invalid email or password'), findsOneWidget);
  });

  testWidgets('Register page creates account and stores session',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(RegisterPage(repository: repo), auth, repo));

    await tester.enterText(find.byKey(const Key('email_field')), 'new@b.com');
    await tester.enterText(
        find.byKey(const Key('password_field')), 'password123');
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isTrue);
    expect(auth.user!.email, 'new@b.com');
  });

  testWidgets('Register rejects a short password (client validation)',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(RegisterPage(repository: repo), auth, repo));

    await tester.enterText(find.byKey(const Key('email_field')), 'new@b.com');
    await tester.enterText(find.byKey(const Key('password_field')), 'short');
    await tester.tap(find.byKey(const Key('submit_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
    expect(find.text('Use at least 8 characters'), findsOneWidget);
  });

  testWidgets('Account page: logged out shows Login/Register buttons',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(const AccountPage(), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
    expect(find.byKey(const Key('go_register_button')), findsOneWidget);
  });

  testWidgets('Account page: logged in shows email, brokers, logout',
      (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: '',
      connectedBrokers: 2));
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(const AccountPage(), auth, repo));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account_email')), findsOneWidget);
    expect(find.text('a@b.com'), findsOneWidget);
    expect(find.text('Connected brokers: 2'), findsOneWidget);
    expect(find.byKey(const Key('logout_button')), findsOneWidget);
  });

  testWidgets('Logout flow clears the session', (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(const AccountPage(), auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('logout_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
    // After logout the logged-out view appears.
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
  });
}
