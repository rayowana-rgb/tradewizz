import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local stale-while-revalidate cache for the Portfolio Health response.
///
/// The Account page reads the cached value synchronously-ish on open so it can
/// render the last known health immediately (no loading spinner), then
/// revalidates in the background. The cache is keyed per user so signing in as
/// a different account never shows another user's health.
///
/// We persist the *raw* backend JSON (the same map `PortfolioHealth.fromJson`
/// already consumes) so no extra model serialization is needed.
abstract class PortfolioHealthCache {
  /// Returns the cached raw health JSON for [userKey], or null if absent.
  Future<Map<String, dynamic>?> read(String userKey);

  /// Stores the raw health JSON for [userKey].
  Future<void> write(String userKey, Map<String, dynamic> rawHealth);
}

/// SharedPreferences-backed implementation.
class SharedPrefsPortfolioHealthCache implements PortfolioHealthCache {
  static const _prefix = 'tradewiz.portfolio_health.v1.';

  String _key(String userKey) => '$_prefix${_safe(userKey)}';

  // A token can be long / contain odd chars; use a stable short fingerprint so
  // we don't store the raw bearer token as a preferences key.
  String _safe(String userKey) {
    if (userKey.isEmpty) return 'anon';
    var hash = 0;
    for (final code in userKey.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  @override
  Future<Map<String, dynamic>?> read(String userKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(userKey));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String userKey, Map<String, dynamic> rawHealth) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_key(userKey), jsonEncode(rawHealth));
    } catch (_) {
      // Best-effort cache: a write failure must never break the page.
    }
  }
}

/// In-memory cache for tests (no disk).
class InMemoryPortfolioHealthCache implements PortfolioHealthCache {
  final Map<String, Map<String, dynamic>> _store = {};

  @override
  Future<Map<String, dynamic>?> read(String userKey) async => _store[userKey];

  @override
  Future<void> write(String userKey, Map<String, dynamic> rawHealth) async {
    _store[userKey] = rawHealth;
  }
}
