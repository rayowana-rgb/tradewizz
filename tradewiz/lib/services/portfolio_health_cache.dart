import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Local stale-while-revalidate cache for the per-user portfolio "insight"
/// responses (Portfolio Health, AI Portfolio Manager, Portfolio Rebalancing).
///
/// Cards read the cached value on open so they can render the last known result
/// immediately (no loading spinner), then revalidate in the background. The
/// cache is namespaced by [feature] and keyed per user so signing in as a
/// different account never shows another user's data.
///
/// We persist the *raw* backend JSON (the same map each model's `fromJson`
/// already consumes) so no extra model serialization is needed.
abstract class PortfolioInsightCache {
  /// Returns the cached raw JSON for [feature]/[userKey], or null if absent.
  Future<Map<String, dynamic>?> read(String feature, String userKey);

  /// Stores the raw JSON for [feature]/[userKey].
  Future<void> write(String feature, String userKey, Map<String, dynamic> raw);
}

// Back-compat alias: the original health-only name still works.
typedef PortfolioHealthCache = PortfolioInsightCache;

/// Stable feature namespaces used as cache keys.
class PortfolioInsightFeature {
  static const health = 'health';
  static const manager = 'manager';
  static const rebalance = 'rebalance';
  static const journal = 'journal';
}

/// SharedPreferences-backed implementation.
class SharedPrefsPortfolioInsightCache implements PortfolioInsightCache {
  static const _prefix = 'tradewiz.portfolio_insight.v1.';

  String _key(String feature, String userKey) =>
      '$_prefix$feature.${_safe(userKey)}';

  // A token can be long / contain odd chars; use a stable short fingerprint so
  // we never store the raw bearer token as a preferences key.
  String _safe(String userKey) {
    if (userKey.isEmpty) return 'anon';
    var hash = 0;
    for (final code in userKey.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return hash.toRadixString(16);
  }

  @override
  Future<Map<String, dynamic>?> read(String feature, String userKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(feature, userKey));
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
  Future<void> write(
      String feature, String userKey, Map<String, dynamic> raw) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.setString(_key(feature, userKey), jsonEncode(raw));
    } catch (_) {
      // Best-effort cache: a write failure must never break the page.
    }
  }
}

// Back-compat alias for the original class name.
typedef SharedPrefsPortfolioHealthCache = SharedPrefsPortfolioInsightCache;

/// In-memory cache for tests (no disk).
class InMemoryPortfolioInsightCache implements PortfolioInsightCache {
  final Map<String, Map<String, dynamic>> _store = {};

  @override
  Future<Map<String, dynamic>?> read(String feature, String userKey) async =>
      _store['$feature::$userKey'];

  @override
  Future<void> write(
      String feature, String userKey, Map<String, dynamic> raw) async {
    _store['$feature::$userKey'] = raw;
  }
}

// Back-compat alias for the original class name.
typedef InMemoryPortfolioHealthCache = InMemoryPortfolioInsightCache;
