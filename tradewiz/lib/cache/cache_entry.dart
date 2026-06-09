/// A single cached record with metadata.
///
/// Stored as a plain JSON-serialisable map in Hive so we never need generated
/// type adapters (keeps the build dependency-free). [data] is whatever the
/// caller stored (already JSON-encodable: the raw API response map / list).
///
/// Freshness model:
///   * `expires_at` is `cached_at + ttl`.
///   * An entry past `expires_at` is **stale** but still usable for display
///     (stale-while-revalidate / offline). It is the caller's choice whether
///     to render it.
class CacheEntry<T> {
  CacheEntry({
    required this.data,
    required this.cachedAt,
    required this.expiresAt,
  });

  /// The cached payload (a JSON-encodable value: Map, List, num, String...).
  final T data;

  /// When the entry was written.
  final DateTime cachedAt;

  /// When the entry becomes stale (`cachedAt + ttl`).
  final DateTime expiresAt;

  /// True once we are past [expiresAt]. Stale data may still be displayed.
  bool get stale => DateTime.now().isAfter(expiresAt);

  /// True if [stale] would be false at [now] (injectable for tests).
  bool isFreshAt(DateTime now) => !now.isAfter(expiresAt);

  /// Age of the entry right now.
  Duration get age => DateTime.now().difference(cachedAt);

  /// Age at an injected clock (tests).
  Duration ageAt(DateTime now) => now.difference(cachedAt);

  // --- serialisation (plain map, no Hive adapters) --------------------------

  Map<String, dynamic> toMap() => {
        'data': data,
        'cached_at': cachedAt.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        // `stale` is recomputed on read, but we persist a snapshot too so the
        // raw record matches the spec'd shape.
        'stale': stale,
      };

  static CacheEntry<dynamic>? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<dynamic, dynamic>();
    final cachedAt = DateTime.tryParse(map['cached_at']?.toString() ?? '');
    final expiresAt = DateTime.tryParse(map['expires_at']?.toString() ?? '');
    if (cachedAt == null || expiresAt == null) return null;
    return CacheEntry<dynamic>(
      data: map['data'],
      cachedAt: cachedAt,
      expiresAt: expiresAt,
    );
  }
}

/// A value returned from the cached repository layer, carrying freshness
/// metadata for the UI ("Updated 5 min ago", "Cached • 5 min ago", offline
/// banners). [value] is the typed, parsed model.
class Cached<T> {
  const Cached({
    required this.value,
    required this.isCached,
    required this.lastUpdated,
    this.stale = false,
    this.offline = false,
  });

  /// The parsed model value.
  final T value;

  /// True when this value came from the local cache (not a fresh network hit).
  final bool isCached;

  /// When the underlying data was last fetched from the network.
  final DateTime lastUpdated;

  /// True when the cached value is past its TTL (still shown, but old).
  final bool stale;

  /// True when we are serving cache because the network was unavailable.
  final bool offline;

  Duration get age => DateTime.now().difference(lastUpdated);

  Cached<T> copyWith({
    T? value,
    bool? isCached,
    DateTime? lastUpdated,
    bool? stale,
    bool? offline,
  }) =>
      Cached<T>(
        value: value ?? this.value,
        isCached: isCached ?? this.isCached,
        lastUpdated: lastUpdated ?? this.lastUpdated,
        stale: stale ?? this.stale,
        offline: offline ?? this.offline,
      );

  /// Human label, e.g. "Updated 5 min ago" (fresh) or "Cached • 5 min ago".
  String freshnessLabel({DateTime? now}) {
    final t = now ?? DateTime.now();
    final ago = _humanAgo(t.difference(lastUpdated));
    if (isCached) return 'Cached • $ago';
    return 'Updated $ago';
  }
}

/// "5 min ago", "just now", "20s ago", "2h ago".
String _humanAgo(Duration d) {
  if (d.inSeconds < 5) return 'just now';
  if (d.inSeconds < 60) return '${d.inSeconds}s ago';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Public helper so widgets can format an arbitrary timestamp consistently.
String humanAgo(Duration d) => _humanAgo(d);
