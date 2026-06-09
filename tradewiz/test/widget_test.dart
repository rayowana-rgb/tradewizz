import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tradewiz/main.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/services/user_prefs_scope.dart';
import 'package:tradewiz/services/user_prefs_store.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';

/// In-memory prefs persistence so tests don't touch disk.
class _MemPrefs implements UserPrefsPersistence {
  _MemPrefs(this._value);
  UserPrefs? _value;
  @override
  Future<UserPrefs?> load() async => _value;
  @override
  Future<void> save(UserPrefs v) async => _value = v;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('First launch shows onboarding welcome', (tester) async {
    await tester.pumpWidget(const TradeWizApp());
    await tester.pumpAndSettle();

    // Onboarding is the first thing a brand-new user sees (Phase A).
    expect(find.text('Welcome to TradeWizz'), findsOneWidget);
    expect(find.text('Your personal AI investing advisor.'), findsOneWidget);
    expect(find.byKey(const Key('onboarding_get_started')), findsOneWidget);
  });

  testWidgets('Onboarded user lands on the Home shell with 5 tabs',
      (tester) async {
    // An already-onboarded profile -> RootGate shows the main shell.
    final prefs = UserPrefsStore(
      persistence: _MemPrefs(const UserPrefs(onboarded: true)),
    );
    await prefs.load();

    await tester.pumpWidget(
      MaterialApp(
        home: AuthScope(
          store: AuthStore(),
          child: WatchlistScope(
            store: WatchlistStore(),
            child: UserPrefsScope(
              store: prefs,
              child: RepositoryScope(
                repository: StockRepository(),
                child: const RootGate(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final navBar = find.byType(NavigationBar);
    expect(navBar, findsOneWidget);

    // Phase H: final navigation Home / Watchlist / Explore / Portfolio /
    // Account, in order.
    for (final label in [
      'Home',
      'Watchlist',
      'Explore',
      'Portfolio',
      'Account',
    ]) {
      expect(
        find.descendant(of: navBar, matching: find.text(label)),
        findsOneWidget,
        reason: 'expected "$label" destination in bottom navigation',
      );
    }

    // Old destinations are gone.
    expect(find.descendant(of: navBar, matching: find.text('Dashboard')),
        findsNothing);
    expect(find.descendant(of: navBar, matching: find.text('AI Analysis')),
        findsNothing);
  });
}
