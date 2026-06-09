import 'dart:async';

import '../cache/cache_entry.dart';
import '../cache/cache_service.dart';
import '../models/market.dart';
import '../snapshot/snapshot_keys.dart';
import '../snapshot/snapshot_metrics.dart';
import '../snapshot/snapshot_models.dart';
import 'manifest_service.dart';

/// Where the last-seen manifest + CDN sync metadata live in Hive.
class CdnKeys {
  CdnKeys._();
  static const String manifest = 'cdn_manifest';
  static const String lastSync = 'cdn_last_sync';

  /// The per-market dashboard object key on the CDN (Phase B layout).
  static String dashboardObject(Market m) => 'markets/${m.code}/dashboard.json';
}

/// Result of a CDN sync pass, surfaced to the UI / inspector (Phase J).
class CdnSyncResult {
  CdnSyncResult({
    required this.source,
    required this.changed,
    this.manifestVersion,
    this.bytes = 0,
  });

  /// Where the snapshot ultimately came from this pass.
  final SnapshotSource source;

  /// Whether the dashboard snapshot was updated in Hive.
  final bool changed;
  final String? manifestVersion;
  final int bytes;
}

enum SnapshotSource { hive, cdn, backend }

extension SnapshotSourceLabel on SnapshotSource {
  String get label => switch (this) {
        SnapshotSource.hive => 'Hive',
        SnapshotSource.cdn => 'CDN',
        SnapshotSource.backend => 'Backend',
      };
}

/// Offline-first CDN repository (Phases E/F/G/H/K/L).
///
/// Flow (Phase F): the app reads the Hive snapshot and renders immediately; in
/// the background it fetches the manifest, compares versions/hashes (Phase E),
/// and only downloads objects whose hash changed (Phase G). A downloaded object
/// is validated (Phase K) before it replaces the valid Hive copy. If the CDN is
/// unreachable, Hive is used (Phase H) and nothing is overwritten.
class CdnRepository {
  CdnRepository(
    this._manifest, {
    CacheService? cache,
    SnapshotMetrics? metrics,
  })  : _cache = cache ?? CacheService.instance,
        metrics = metrics ?? SnapshotMetrics();

  final ManifestService _manifest;
  final CacheService _cache;
  final SnapshotMetrics metrics;

  bool get enabled => _manifest.enabled;

  // --- Phase F step 1: render-now from Hive -------------------------------

  /// The locally cached dashboard snapshot (never hits the network).
  DashboardSnapshot? peekDashboard(Market market) {
    final raw = _cache.read<Map>(SnapshotKeys.dashboard(market));
    if (raw == null) return null;
    return DashboardSnapshot(Map<String, dynamic>.from(raw), market: market);
  }

  /// The manifest version stored locally (for the inspector — Phase J).
  String? get localManifestVersion {
    final raw = _cache.read<Map>(CdnKeys.manifest);
    if (raw == null) return null;
    return (raw['version'] ?? '').toString();
  }

  CdnManifest? get localManifest {
    final raw = _cache.read<Map>(CdnKeys.manifest);
    if (raw == null) return null;
    try {
      return CdnManifest.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  DateTime? get lastCdnSync {
    final iso = _cache.read<String>(CdnKeys.lastSync);
    return iso == null ? null : DateTime.tryParse(iso);
  }

  // --- Phase E/F/G: background sync ---------------------------------------

  /// Check the CDN manifest and update Hive for the dashboard of [market] when
  /// (and only when) its content hash changed. Offline-first: any failure
  /// keeps the existing Hive snapshot (Phase H) and reports [SnapshotSource].
  Future<CdnSyncResult> sync(Market market) async {
    if (!enabled) {
      return CdnSyncResult(source: SnapshotSource.hive, changed: false);
    }
    metrics.cdnManifestFetch();
    final remote = await _manifest.fetchManifest();
    if (remote == null) {
      // CDN unreachable -> use Hive (Phase H).
      if (peekDashboard(market) != null) metrics.offlineLoad();
      return CdnSyncResult(source: SnapshotSource.hive, changed: false);
    }

    final prior = localManifest;
    final key = CdnKeys.dashboardObject(market);
    final changedKeys = remote.changedKeys(prior).toSet();

    // Phase E step 3: unchanged -> use local Hive snapshot, no download.
    final dashboardChanged = changedKeys.contains(key) ||
        !_cache.has(SnapshotKeys.dashboard(market));
    if (!dashboardChanged) {
      metrics.cdnCacheHit();
      // Still persist the (possibly new) manifest version for the inspector.
      await _storeManifest(remote);
      return CdnSyncResult(
        source: SnapshotSource.hive,
        changed: false,
        manifestVersion: remote.version,
      );
    }

    // Phase G: download ONLY the changed dashboard object.
    metrics.cdnCacheMiss();
    final obj = await _manifest.fetchObject(key);
    if (obj == null || !_validDashboard(obj.json, market)) {
      // Phase K: never overwrite a valid Hive snapshot with a bad download.
      if (peekDashboard(market) != null) metrics.offlineLoad();
      await _storeManifest(remote);
      return CdnSyncResult(
        source: SnapshotSource.hive,
        changed: false,
        manifestVersion: remote.version,
      );
    }

    metrics.cdnSnapshotDownload(obj.bytes);
    await _cache.write(
      SnapshotKeys.dashboard(market),
      obj.json,
      ttl: SnapshotKeys.dashboardTtl,
    );
    metrics.snapshotUpdate();
    await _storeManifest(remote);
    return CdnSyncResult(
      source: SnapshotSource.cdn,
      changed: true,
      manifestVersion: remote.version,
      bytes: obj.bytes,
    );
  }

  Future<void> _storeManifest(CdnManifest m) async {
    await _cache.write(CdnKeys.manifest, m.toJson(),
        ttl: const Duration(days: 365));
    await _cache.write(CdnKeys.lastSync, DateTime.now().toIso8601String(),
        ttl: const Duration(days: 365));
  }

  // --- Phase K: validation -------------------------------------------------

  /// A downloaded dashboard object must be a non-empty map with the required
  /// envelope before it is allowed to replace the Hive copy.
  bool _validDashboard(Map<String, dynamic> json, Market market) {
    if (json.isEmpty) return false;
    if (json['error'] != null) return false;
    if (!json.containsKey('generated_at')) return false;
    // Must contain at least one real section (guards partial downloads).
    const sections = [
      'indices',
      'morning_brief',
      'rotation',
      'radar',
      'daily_picks',
      'multibagger',
      'watchlist_ai',
      'notifications',
    ];
    final hasSection = sections.any((s) => json[s] != null);
    return hasSection;
  }

  CacheEntry<dynamic>? dashboardEntry(Market market) =>
      _cache.readEntry(SnapshotKeys.dashboard(market));
}
