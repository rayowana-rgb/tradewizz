import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/main.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';
import 'package:tradewiz/services/repository_scope.dart';
import 'package:tradewiz/services/user_prefs_scope.dart';
import 'package:tradewiz/services/user_prefs_store.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';

class _MemPrefs implements UserPrefsPersistence {
  _MemPrefs(this.value);
  UserPrefs? value;
  @override
  Future<UserPrefs?> load() async => value;
  @override
  Future<void> save(UserPrefs v) async => value = v;
}

Future<void> _pumpShell(WidgetTester tester) async {
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
}

void main() {
  // Phase A: AI Analysis restored to the main nav; Portfolio removed.
  testWidgets('bottom nav contains AI Analysis and not Portfolio',
      (tester) async {
    await _pumpShell(tester);
    final navBar = find.byType(NavigationBar);

    expect(find.descendant(of: navBar, matching: find.text('AI Analysis')),
        findsOneWidget);
    expect(find.descendant(of: navBar, matching: find.text('Portfolio')),
        findsNothing);
    // Five tabs total in the expected order.
    for (final t in ['Home', 'Watchlist', 'Explore', 'AI Analysis',
        'Account']) {
      expect(find.descendant(of: navBar, matching: find.text(t)),
          findsOneWidget);
    }
  });

  testWidgets('tapping AI Analysis opens the analysis page', (tester) async {
    await _pumpShell(tester);
    await tester.tap(find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('AI Analysis'),
    ));
    await tester.pumpAndSettle();
    // The AI Analysis page is shown (symbol input + Run button live here).
    expect(find.byType(AiAnalysisPage), findsOneWidget);
  });
}
