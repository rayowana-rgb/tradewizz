import 'package:flutter/widgets.dart';

import '../cache/cache_service.dart';
import '../cache/cached_repository.dart';
import '../cdn/cdn_repository.dart';
import '../cdn/manifest_service.dart';
import '../repositories/stock_repository.dart';
import '../snapshot/snapshot_repository.dart';

/// Provides a [StockRepository] (and its SWR-cached wrapper) to the widget tree
/// so pages (and pushed routes like the analysis detail) share one configured
/// instance.
class RepositoryScope extends InheritedWidget {
  RepositoryScope({
    super.key,
    required this.repository,
    CachedRepository? cached,
    SnapshotRepository? snapshot,
    CdnRepository? cdn,
    required super.child,
  })  : cached = cached ??
            // Default to an ISOLATED in-memory cache so each scope (e.g. a
            // widget test) is independent. Production wires the shared
            // Hive-backed [CacheService.instance] explicitly in main().
            CachedRepository(repository, cache: CacheService.inMemory()),
        snapshot = snapshot ??
            SnapshotRepository(repository, cache: CacheService.inMemory()),
        cdn = cdn ??
            CdnRepository(ManifestService(), cache: CacheService.inMemory());

  final StockRepository repository;

  /// SWR / offline-aware wrapper around [repository]. Additive: existing call
  /// sites can keep using [repository]; cache-aware widgets use this.
  final CachedRepository cached;

  /// Offline-first snapshot repository (Phase 6).
  final SnapshotRepository snapshot;

  /// Global Snapshot CDN repository (Phase 7).
  final CdnRepository cdn;

  /// Returns the provided repository, or a default one if no scope exists
  /// (keeps widgets usable in isolation).
  static StockRepository of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RepositoryScope>();
    return scope?.repository ?? StockRepository();
  }

  /// Returns the cached/SWR wrapper, or a default one if no scope exists.
  static CachedRepository cachedOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RepositoryScope>();
    return scope?.cached ?? CachedRepository(StockRepository());
  }

  /// Returns the snapshot repository, or a default one if no scope exists.
  static SnapshotRepository snapshotOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RepositoryScope>();
    return scope?.snapshot ?? SnapshotRepository(StockRepository());
  }

  /// Returns the CDN repository, or a default one if no scope exists.
  static CdnRepository cdnOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RepositoryScope>();
    return scope?.cdn ?? CdnRepository(ManifestService());
  }

  @override
  bool updateShouldNotify(RepositoryScope oldWidget) =>
      oldWidget.repository != repository ||
      oldWidget.cached != cached ||
      oldWidget.snapshot != snapshot ||
      oldWidget.cdn != cdn;
}
