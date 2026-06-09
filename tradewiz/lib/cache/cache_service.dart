import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';

import 'cache_entry.dart';
import 'cache_keys.dart';

/// Minimal key/value store the cache can write through. Hive's [Box] satisfies
/// this implicitly; tests can pass an in-memory map instead so they never need
/// a real Hive directory or `path_provider`.
abstract class CacheBackend {
  Object? get(String key);
  Future<void> put(String key, Object? value);
  Future<void> delete(String key);
  Iterable<String> get keys;
  Future<void> clear();
}

/// In-memory backend used for tests (and as a safe fallback if Hive fails to
/// open, e.g. in a restricted environment).
class MemoryCacheBackend implements CacheBackend {
  final Map<String, Object?> _store = {};

  @override
  Object? get(String key) => _store[key];

  @override
  Future<void> put(String key, Object? value) async => _store[key] = value;

  @override
  Future<void> delete(String key) async => _store.remove(key);

  @override
  Iterable<String> get keys => _store.keys;

  @override
  Future<void> clear() async => _store.clear();
}

/// Thin adapter so a Hive [Box] looks like a [CacheBackend].
class _HiveBackend implements CacheBackend {
  _HiveBackend(this._box);
  final Box _box;

  @override
  Object? get(String key) => _box.get(key);

  @override
  Future<void> put(String key, Object? value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);

  @override
  Iterable<String> get keys => _box.keys.cast<String>();

  @override
  Future<void> clear() async => _box.clear();
}

/// Generic, typed, expiring cache.
///
/// Stores JSON-encodable payloads wrapped in a [CacheEntry] (which keeps the
/// `cached_at` / `expires_at` / `stale` metadata). Readers get back the raw
/// payload plus freshness, and choose whether to use stale data.
///
/// This service is intentionally model-agnostic: callers serialise their model
/// to a Map/List before [write] and parse it after [read]. That keeps the
/// cache layer additive and decoupled from every model class.
class CacheService {
  CacheService._(this._backend);

  final CacheBackend _backend;

  /// Test/offline-safe constructor backed by memory.
  factory CacheService.inMemory() => CacheService._(MemoryCacheBackend());

  /// Construct from an arbitrary backend (advanced/testing).
  factory CacheService.withBackend(CacheBackend backend) =>
      CacheService._(backend);

  static CacheService? _instance;

  /// The process-wide cache. Call [init] once at startup before use; until
  /// then a memory-backed instance is returned so nothing crashes.
  static CacheService get instance => _instance ??= CacheService.inMemory();

  /// Open Hive and the cache box. Safe to call multiple times. If Hive can't
  /// be opened (e.g. no platform channels in a unit test), we fall back to an
  /// in-memory backend so the app still runs.
  static Future<CacheService> init() async {
    if (_instance != null && _instance!._backend is! MemoryCacheBackend) {
      return _instance!;
    }
    try {
      await Hive.initFlutter();
      final box = await Hive.openBox(CacheKeys.boxName);
      _instance = CacheService._(_HiveBackend(box));
    } catch (_) {
      _instance = CacheService.inMemory();
    }
    return _instance!;
  }

  /// Override the singleton (tests).
  static void overrideInstance(CacheService service) => _instance = service;

  // --- core API -------------------------------------------------------------

  /// Write [data] under [key] with a freshness window of [ttl].
  /// [data] MUST be JSON-encodable (Map/List/num/String/bool/null).
  Future<void> write(String key, Object? data, {required Duration ttl}) async {
    final now = DateTime.now();
    final entry = CacheEntry<Object?>(
      data: data,
      cachedAt: now,
      expiresAt: now.add(ttl),
    );
    await _backend.put(key, entry.toMap());
  }

  /// Read the raw entry (with metadata) or null when absent/corrupt.
  CacheEntry<dynamic>? readEntry(String key) =>
      CacheEntry.fromMap(_backend.get(key));

  /// Read just the payload, optionally rejecting stale entries.
  ///
  /// When [allowStale] is false, an expired entry returns null (caller will
  /// refetch). When true (default), stale data is returned for SWR/offline.
  T? read<T>(String key, {bool allowStale = true}) {
    final entry = readEntry(key);
    if (entry == null) return null;
    if (!allowStale && entry.stale) return null;
    return entry.data as T?;
  }

  bool has(String key) => _backend.get(key) != null;

  bool isStale(String key) {
    final entry = readEntry(key);
    return entry == null ? true : entry.stale;
  }

  Future<void> remove(String key) => _backend.delete(key);

  Future<void> clearAll() => _backend.clear();

  /// All keys currently held (for the Cache Inspector).
  List<String> keys() => _backend.keys.toList();

  /// A metadata snapshot for the Cache Inspector.
  List<CacheStat> stats({DateTime? now}) {
    final t = now ?? DateTime.now();
    final out = <CacheStat>[];
    for (final key in keys()) {
      final entry = readEntry(key);
      if (entry == null) continue;
      out.add(CacheStat(
        key: key,
        label: CacheKeys.labelFor(key),
        cachedAt: entry.cachedAt,
        expiresAt: entry.expiresAt,
        age: entry.ageAt(t),
        stale: !entry.isFreshAt(t),
        ttl: CacheKeys.ttlFor(key),
      ));
    }
    out.sort((a, b) => a.label.compareTo(b.label));
    return out;
  }
}

/// One row in the Cache Inspector.
class CacheStat {
  CacheStat({
    required this.key,
    required this.label,
    required this.cachedAt,
    required this.expiresAt,
    required this.age,
    required this.stale,
    required this.ttl,
  });

  final String key;
  final String label;
  final DateTime cachedAt;
  final DateTime expiresAt;
  final Duration age;
  final bool stale;
  final Duration ttl;

  String get ageLabel => humanAgo(age);
}
