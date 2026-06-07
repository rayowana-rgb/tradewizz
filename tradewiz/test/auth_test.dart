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
import 'package:tradewiz/services/social_sign_in.dart';

/// Fake SocialSignIn for widget tests: returns canned id tokens (or null to
/// simulate a user cancelling), and toggles platform availability so we can
/// assert iOS-only Apple behaviour without a real device.
class _FakeSocial implements SocialSignIn {
  _FakeSocial({
    this.googleAvailable = true,
    this.appleAvailable = true,
    this.googleToken = 'GID',
    this.appleToken = 'AID',
  });

  @override
  final bool googleAvailable;
  @override
  final bool appleAvailable;
  final String? googleToken;
  final String? appleToken;

  @override
  Future<String?> googleIdToken() async => googleToken;
  @override
  Future<String?> appleIdToken() async => appleToken;
}

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
    if (req.url.path.endsWith('/auth/google') ||
        req.url.path.endsWith('/auth/apple')) {
      final provider =
          req.url.path.endsWith('/auth/google') ? 'GOOGLE' : 'APPLE';
      return http.Response(
        jsonEncode({
          'access_token': 'SOCIAL-$provider',
          'token_type': 'bearer',
          'user': {
            ...userJson('social@$provider.com'),
            'provider': provider,
          },
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

/// Like _authRepo but also serves a minimal unified portfolio so the Account
/// page's Portfolio summary card can populate.
StockRepository _authRepoWithPortfolio() {
  final fake = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/portfolio')) {
      return http.Response(
        jsonEncode({
          'summary': {
            'total_equity': 150000.0,
            'cash': 100000.0,
            'buying_power': 200000.0,
            'market_value': 41260.0,
            'floating_pnl': 3260.0,
            'realized_pnl': 0.0,
          },
          'positions': <Map<String, dynamic>>[],
          'brokers': ['MOOMOO'],
          'errors': <Map<String, dynamic>>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
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
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, socialSignIn: _FakeSocial()),
        auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
    // Register option is clearly present when logged out.
    expect(find.byKey(const Key('go_register_button')), findsOneWidget);
    expect(find.text('Register with Email'), findsOneWidget);
  });

  testWidgets('Logged out shows Google + Apple buttons (both available)',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, socialSignIn: _FakeSocial()),
        auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('continue_google_button')), findsOneWidget);
    expect(find.byKey(const Key('continue_apple_button')), findsOneWidget);
  });

  testWidgets('Apple button hidden on Android (appleAvailable=false)',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(
          repository: repo,
          socialSignIn: _FakeSocial(appleAvailable: false),
        ),
        auth, repo));
    await tester.pumpAndSettle();
    // Google still shows on Android; Apple does not.
    expect(find.byKey(const Key('continue_google_button')), findsOneWidget);
    expect(find.byKey(const Key('continue_apple_button')), findsNothing);
  });

  testWidgets('Google login success stores the TradeWizz session',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, socialSignIn: _FakeSocial()),
        auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue_google_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isTrue);
    expect(auth.token, 'SOCIAL-GOOGLE'); // only the TradeWizz JWT is stored
    expect(auth.user!.provider, 'GOOGLE');
  });

  testWidgets('Apple login success stores the TradeWizz session',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo, socialSignIn: _FakeSocial()),
        auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue_apple_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isTrue);
    expect(auth.token, 'SOCIAL-APPLE');
    expect(auth.user!.provider, 'APPLE');
  });

  testWidgets('Cancelling Google sign-in leaves the session untouched',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(
          repository: repo,
          socialSignIn: _FakeSocial(googleToken: null), // user cancels
        ),
        auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue_google_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
  });

  testWidgets('Cancelling Apple sign-in leaves the session untouched',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(
          repository: repo,
          socialSignIn: _FakeSocial(appleToken: null), // user cancels
        ),
        auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('continue_apple_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
  });

  testWidgets('No social buttons when neither provider is available',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(
        AccountPage(
          repository: repo,
          socialSignIn:
              _FakeSocial(googleAvailable: false, appleAvailable: false),
        ),
        auth, repo));
    await tester.pumpAndSettle();
    // Email login/register still present; no social buttons.
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
    expect(find.byKey(const Key('continue_google_button')), findsNothing);
    expect(find.byKey(const Key('continue_apple_button')), findsNothing);
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
    // Logout sits below the new Portfolio section; scroll it into view.
    await tester.scrollUntilVisible(
      find.byKey(const Key('logout_button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('logout_button')), findsOneWidget);
  });

  testWidgets('Account page shows the Portfolio section when logged in',
      (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _authRepoWithPortfolio();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    // Section header + summary card + Open Portfolio button.
    expect(find.byKey(const Key('account_portfolio_section')), findsOneWidget);
    expect(find.byKey(const Key('account_portfolio_card')), findsOneWidget);
    expect(find.byKey(const Key('open_portfolio_button')), findsOneWidget);
    // Summary populated from the fake backend.
    expect(find.byKey(const Key('account_total_equity')), findsOneWidget);
    expect(find.text('150000.00'), findsOneWidget);
    expect(find.byKey(const Key('account_cash')), findsOneWidget);
    // Performance + Positions entries.
    expect(find.byKey(const Key('portfolio_positions_tile')), findsOneWidget);
    expect(find.byKey(const Key('portfolio_performance_tile')), findsOneWidget);
  });

  testWidgets('Account page hides Portfolio section when logged out',
      (tester) async {
    final auth = AuthStore();
    final repo = _authRepoWithPortfolio();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account_portfolio_section')), findsNothing);
    expect(find.byKey(const Key('open_portfolio_button')), findsNothing);
  });

  testWidgets('Tapping Open Portfolio opens the Portfolio page',
      (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _authRepoWithPortfolio();
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open_portfolio_button')));
    await tester.pumpAndSettle();

    // The pushed Portfolio page shows its sub-tabs.
    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Positions'), findsOneWidget);
    expect(find.text('Orders'), findsOneWidget);
    expect(find.text('Performance'), findsOneWidget);
  });

  testWidgets('Account page stays usable when portfolio fails to load',
      (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _authRepo(); // 404s /portfolio
    await tester.pumpWidget(_wrap(
        AccountPage(repository: repo), auth, repo));
    await tester.pumpAndSettle();

    // Friendly error but the Open Portfolio button + logout remain.
    expect(find.byKey(const Key('account_portfolio_error')), findsOneWidget);
    expect(find.byKey(const Key('open_portfolio_button')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('logout_button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('logout_button')), findsOneWidget);
  });

  testWidgets('Logout flow clears the session', (tester) async {
    final auth = AuthStore();
    await auth.setSession('TOKEN', const UserProfile(
      id: 1, email: 'a@b.com', createdAt: '', updatedAt: ''));
    final repo = _authRepo();
    await tester.pumpWidget(_wrap(const AccountPage(), auth, repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('logout_button')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('logout_button')));
    await tester.pumpAndSettle();

    expect(auth.isLoggedIn, isFalse);
    // After logout the logged-out view appears.
    expect(find.byKey(const Key('go_login_button')), findsOneWidget);
  });
}
