import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/home/activation_metrics.dart';
import 'package:tradewiz/home/activation_scope.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user_profile_prefs.dart';
import 'package:tradewiz/pages/onboarding_page.dart';
import 'package:tradewiz/services/user_prefs_scope.dart';
import 'package:tradewiz/services/user_prefs_store.dart';
import 'package:tradewiz/services/watchlist_scope.dart';
import 'package:tradewiz/services/watchlist_store.dart';

class _MemPrefs implements UserPrefsPersistence {
  UserPrefs? value;
  @override
  Future<UserPrefs?> load() async => value;
  @override
  Future<void> save(UserPrefs v) async => value = v;
}

void main() {
  // --- store ---------------------------------------------------------------
  group('UserPrefsStore', () {
    test('persists markets, interests, and onboarding completion', () async {
      final mem = _MemPrefs();
      final store = UserPrefsStore(persistence: mem);
      await store.load();
      expect(store.onboarded, isFalse);

      await store.setMarkets([Market.idx, Market.us]);
      await store.setInterests([Interest.growth, Interest.momentum]);
      await store.completeOnboarding();

      expect(store.onboarded, isTrue);
      expect(store.prefs.primaryMarket, Market.idx);
      // Reload from the same persistence -> survives.
      final reloaded = UserPrefsStore(persistence: mem);
      await reloaded.load();
      expect(reloaded.onboarded, isTrue);
      expect(reloaded.prefs.markets, contains(Market.us));
      expect(reloaded.prefs.interests, contains(Interest.growth));
    });

    test('persists Account section collapsed state across reloads', () async {
      final mem = _MemPrefs();
      final store = UserPrefsStore(persistence: mem);
      await store.load();
      // Default: expanded (not collapsed).
      expect(store.prefs.holdingsCollapsed, isFalse);
      expect(store.prefs.tradesCollapsed, isFalse);

      await store.setHoldingsCollapsed(true);
      await store.setTradesCollapsed(true);

      // Reload from the same persistence -> the collapsed state survives.
      final reloaded = UserPrefsStore(persistence: mem);
      await reloaded.load();
      expect(reloaded.prefs.holdingsCollapsed, isTrue);
      expect(reloaded.prefs.tradesCollapsed, isTrue);

      // Expanding again is also persisted.
      await reloaded.setHoldingsCollapsed(false);
      final reloaded2 = UserPrefsStore(persistence: mem);
      await reloaded2.load();
      expect(reloaded2.prefs.holdingsCollapsed, isFalse);
      expect(reloaded2.prefs.tradesCollapsed, isTrue);
    });

    test('best-effort backend sync never throws', () async {
      var synced = 0;
      final store = UserPrefsStore(
        persistence: _MemPrefs(),
        backendSync: (_) async {
          synced++;
          throw Exception('boom'); // must be swallowed
        },
      );
      await store.load();
      await store.setMarkets([Market.idx]);
      expect(synced, 1); // attempted, error swallowed
    });
  });

  // --- flow ----------------------------------------------------------------
  testWidgets('completes the 5-screen flow and records activation',
      (tester) async {
    final prefs = UserPrefsStore(persistence: _MemPrefs());
    await prefs.load();
    final watchlist = WatchlistStore();
    final metrics = ActivationMetrics();
    var done = false;

    await tester.pumpWidget(
      MaterialApp(
        home: WatchlistScope(
          store: watchlist,
          child: UserPrefsScope(
            store: prefs,
            child: ActivationScope(
              metrics: metrics,
              child: OnboardingPage(onDone: () => done = true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Screen 1 -> Get Started
    expect(find.text('Welcome to TradeWizz'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding_get_started')));
    await tester.pumpAndSettle();

    // Screen 2 (markets): IDX preselected -> Continue
    expect(find.text('Choose Markets'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding_market_US')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_next')));
    await tester.pumpAndSettle();

    // Screen 3 (interests)
    expect(find.text('What interests you?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding_interest_growth')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_next')));
    await tester.pumpAndSettle();

    // Screen 4 (watchlist): add 3 from the default results.
    expect(find.text('Build Your Watchlist'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding_result_BBCA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_result_TLKM')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_result_GOTO')));
    await tester.pumpAndSettle();
    // "Continue" enabled only at >=3 -> advance to the generate screen.
    await tester.tap(find.byKey(const Key('onboarding_next')));
    await tester.pumpAndSettle(); // page transition + 900ms generate timer

    // The brief has "generated" -> finish CTA is shown.
    await tester.tap(find.byKey(const Key('onboarding_finish')));
    await tester.pumpAndSettle();

    // Onboarding complete + activation recorded.
    expect(done, isTrue);
    expect(prefs.onboarded, isTrue);
    expect(prefs.prefs.markets, contains(Market.us));
    expect(prefs.prefs.interests, contains(Interest.growth));
    expect(watchlist.items.length, greaterThanOrEqualTo(3));
    expect(metrics.count('onboarding_completed'), 1);
    expect(metrics.count('first_watchlist_created'), 1);
    expect(metrics.count('time_to_first_value'), 1);
    expect(metrics.activated, isTrue);
  });

  testWidgets('cannot continue past watchlist with fewer than 3 symbols',
      (tester) async {
    final prefs = UserPrefsStore(persistence: _MemPrefs());
    await prefs.load();
    await tester.pumpWidget(
      MaterialApp(
        home: WatchlistScope(
          store: WatchlistStore(),
          child: UserPrefsScope(
            store: prefs,
            child: ActivationScope(
              metrics: ActivationMetrics(),
              child: const OnboardingPage(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_get_started')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_next'))); // markets
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding_next'))); // interests
    await tester.pumpAndSettle();

    // On the watchlist screen with 0 picks: Continue is disabled.
    expect(find.text('Build Your Watchlist'), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.byKey(const Key('onboarding_next')));
    expect(button.onPressed, isNull);
  });
}
