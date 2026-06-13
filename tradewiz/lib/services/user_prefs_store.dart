import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/market.dart';
import '../models/user_profile_prefs.dart';

/// Persistence seam for [UserPrefs] so the store is testable without disk.
abstract class UserPrefsPersistence {
  Future<UserPrefs?> load();
  Future<void> save(UserPrefs prefs);
}

/// SharedPreferences-backed persistence (Phase A: "store selection locally").
class SharedPrefsUserPrefsPersistence implements UserPrefsPersistence {
  static const _key = 'tradewiz.userprefs.v1';

  @override
  Future<UserPrefs?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return UserPrefs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(UserPrefs value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}

/// Optional backend sync seam (Phase A: "sync to backend profile").
///
/// Best-effort and additive: a failure NEVER blocks onboarding or the UI.
typedef PrefsBackendSync = Future<void> Function(UserPrefs prefs);

/// App-wide personalization store. A [ChangeNotifier] so the home screen and
/// onboarding rebuild when preferences change.
class UserPrefsStore extends ChangeNotifier {
  UserPrefsStore({this.persistence, this.backendSync});

  final UserPrefsPersistence? persistence;
  final PrefsBackendSync? backendSync;

  UserPrefs _prefs = const UserPrefs();
  bool _loaded = false;

  UserPrefs get prefs => _prefs;
  bool get isLoaded => _loaded;

  /// True once onboarding has been completed at least once.
  bool get onboarded => _prefs.onboarded;

  Future<void> load() async {
    if (_loaded) return;
    final stored = await persistence?.load();
    if (stored != null) _prefs = stored;
    _loaded = true;
    notifyListeners();
  }

  /// Persist a new prefs value locally, sync to the backend best-effort, and
  /// notify listeners.
  Future<void> update(UserPrefs next) async {
    _prefs = next;
    notifyListeners();
    await persistence?.save(next);
    _syncBackend(next);
  }

  Future<void> setMarkets(List<Market> markets) =>
      update(_prefs.copyWith(markets: markets));

  Future<void> setInterests(List<Interest> interests) =>
      update(_prefs.copyWith(interests: interests));

  Future<void> setDisplayName(String name) =>
      update(_prefs.copyWith(displayName: name));

  /// Persist the user's preferred broker app (by stable id). Pass null to
  /// clear the preference (the picker then shows no default).
  Future<void> setPreferredBroker(String? brokerId) => update(
        brokerId == null
            ? _prefs.copyWith(clearPreferredBroker: true)
            : _prefs.copyWith(preferredBrokerId: brokerId),
      );

  /// Persist the Account page Holdings section collapsed state (space saver).
  Future<void> setHoldingsCollapsed(bool collapsed) =>
      update(_prefs.copyWith(holdingsCollapsed: collapsed));

  /// Persist the Account page Trade History section collapsed state.
  Future<void> setTradesCollapsed(bool collapsed) =>
      update(_prefs.copyWith(tradesCollapsed: collapsed));

  /// Mark onboarding complete (called after the final screen).
  Future<void> completeOnboarding() => update(
        _prefs.copyWith(onboarded: true, completedAt: DateTime.now()),
      );

  void _syncBackend(UserPrefs next) {
    final sync = backendSync;
    if (sync == null) return;
    // Fire-and-forget; analytics/sync failures must never block the user.
    sync(next).catchError((_) {});
  }
}
