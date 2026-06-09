import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/cdn/cdn_repository.dart';
import 'package:tradewiz/cdn/manifest_service.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/snapshot/snapshot_keys.dart';

const cdnBase = 'https://cdn.tradewiz.app';

Map<String, dynamic> _dashboard({String best = 'US'}) => {
      'generated_at': '2026-06-09T12:00:00Z',
      'market': 'US',
      'indices': {'indices': []},
      'rotation': {'best_market': best, 'markets': []},
      'radar': {'opportunities': []},
    };

String _sha(Object o) {
  // The Flutter side compares hashes by equality only, so any stable function
  // works for the test fixtures; mirror the backend's "sorted compact json".
  return jsonEncode(o);
}

Map<String, dynamic> _manifest({
  required String version,
  required String dashHash,
}) =>
    {
      'version': version,
      'generated_at': '2026-06-09T12:00:00Z',
      'hashes': {'markets/US/dashboard.json': dashHash},
      'sizes': {'markets/US/dashboard.json': 42},
      'markets': {'US': dashHash},
    };

/// Build a ManifestService whose MockClient serves [routes] keyed by path.
ManifestService _service(
  Map<String, http.Response Function()> routes, {
  List<String>? hits,
}) {
  return ManifestService(
    config: const AppConfig(
      baseUrl: 'https://api.tradewiz.app/v1',
      cdnBaseUrl: cdnBase,
    ),
    httpClient: MockClient((req) async {
      final path = req.url.path; // e.g. /snapshots/manifest.json
      hits?.add(path);
      final r = routes[path];
      if (r == null) return http.Response('not found', 404);
      return r();
    }),
  );
}

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  // === Manifest model: compare / delta ===================================
  group('CdnManifest', () {
    test('changedKeys reports all keys when no prior manifest', () {
      final m = CdnManifest.fromJson(_manifest(version: 'v1', dashHash: 'a'));
      expect(m.changedKeys(null), ['markets/US/dashboard.json']);
    });

    test('changedKeys is empty for identical hashes (cache hit)', () {
      final a = CdnManifest.fromJson(_manifest(version: 'v1', dashHash: 'x'));
      final b = CdnManifest.fromJson(_manifest(version: 'v2', dashHash: 'x'));
      expect(b.changedKeys(a), isEmpty);
      expect(b.sameVersion(a), isFalse); // version differs but hashes equal
    });

    test('changedKeys reports only the changed object', () {
      final a = CdnManifest.fromJson(_manifest(version: 'v1', dashHash: 'x'));
      final b = CdnManifest.fromJson(_manifest(version: 'v2', dashHash: 'y'));
      expect(b.changedKeys(a), ['markets/US/dashboard.json']);
    });
  });

  // === Phase E/G: version upgrade triggers a delta download ===============
  test('changed manifest downloads only the dashboard object', () async {
    final dash = _dashboard(best: 'JAPAN');
    final hits = <String>[];
    final svc = _service({
      '/snapshots/manifest.json':
          () => _json(_manifest(version: 'v2', dashHash: _sha(dash))),
      '/snapshots/markets/US/dashboard.json': () => _json(dash),
    }, hits: hits);
    final cache = CacheService.inMemory();
    final repo = CdnRepository(svc, cache: cache);

    final res = await repo.sync(Market.us);
    expect(res.source, SnapshotSource.cdn);
    expect(res.changed, isTrue);
    expect(res.manifestVersion, 'v2');
    // Stored in Hive.
    final stored = cache.read<Map>(SnapshotKeys.dashboard(Market.us))!;
    expect((stored['rotation'] as Map)['best_market'], 'JAPAN');
    // Only manifest + the one dashboard object were fetched (delta).
    expect(hits, contains('/snapshots/manifest.json'));
    expect(hits, contains('/snapshots/markets/US/dashboard.json'));
    expect(repo.metrics.cdnSnapshotDownloadCount, 1);
    expect(repo.metrics.snapshotBytes, greaterThan(0));
  });

  // === Phase E: unchanged manifest -> cache hit, no download ==============
  test('unchanged manifest uses Hive, downloads nothing', () async {
    final dash = _dashboard(best: 'US');
    final hash = _sha(dash);
    final cache = CacheService.inMemory();
    // Seed Hive with the dashboard + matching manifest.
    await cache.write(SnapshotKeys.dashboard(Market.us), dash,
        ttl: SnapshotKeys.dashboardTtl);
    await cache.write(CdnKeys.manifest,
        _manifest(version: 'v1', dashHash: hash), ttl: const Duration(days: 1));

    final hits = <String>[];
    final svc = _service({
      '/snapshots/manifest.json':
          () => _json(_manifest(version: 'v1', dashHash: hash)),
      '/snapshots/markets/US/dashboard.json': () => _json(dash),
    }, hits: hits);
    final repo = CdnRepository(svc, cache: cache);

    final res = await repo.sync(Market.us);
    expect(res.source, SnapshotSource.hive);
    expect(res.changed, isFalse);
    expect(repo.metrics.cdnCacheHitCount, 1);
    // The object was NOT downloaded.
    expect(hits, isNot(contains('/snapshots/markets/US/dashboard.json')));
  });

  // === Phase H: offline fallback ==========================================
  test('CDN unreachable falls back to Hive without error', () async {
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us), _dashboard(),
        ttl: SnapshotKeys.dashboardTtl);
    final svc = _service({}); // every path 404s
    final repo = CdnRepository(svc, cache: cache);

    final res = await repo.sync(Market.us);
    expect(res.source, SnapshotSource.hive);
    expect(res.changed, isFalse);
    expect(repo.metrics.offlineLoadCount, greaterThan(0));
    // Hive snapshot still intact.
    expect(repo.peekDashboard(Market.us), isNotNull);
  });

  test('disabled CDN is a no-op returning Hive source', () async {
    final svc = ManifestService(
      config: const AppConfig(baseUrl: 'https://api/v1'), // no cdnBaseUrl
    );
    final repo = CdnRepository(svc, cache: CacheService.inMemory());
    expect(repo.enabled, isFalse);
    final res = await repo.sync(Market.us);
    expect(res.source, SnapshotSource.hive);
  });

  // === Phase K: cache protection ==========================================
  test('corrupt/empty download never overwrites a valid Hive snapshot',
      () async {
    final good = _dashboard(best: 'US');
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us), good,
        ttl: SnapshotKeys.dashboardTtl);

    final svc = _service({
      // Manifest says the object changed...
      '/snapshots/manifest.json':
          () => _json(_manifest(version: 'v9', dashHash: 'different')),
      // ...but the object download is an EMPTY/partial doc (no sections).
      '/snapshots/markets/US/dashboard.json': () => _json(<String, dynamic>{}),
    });
    final repo = CdnRepository(svc, cache: cache);

    final res = await repo.sync(Market.us);
    expect(res.changed, isFalse);
    // Previous good snapshot kept.
    final stored = cache.read<Map>(SnapshotKeys.dashboard(Market.us))!;
    expect((stored['rotation'] as Map)['best_market'], 'US');
  });

  test('partial download missing required envelope is rejected', () async {
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us), _dashboard(),
        ttl: SnapshotKeys.dashboardTtl);
    final svc = _service({
      '/snapshots/manifest.json':
          () => _json(_manifest(version: 'v9', dashHash: 'diff')),
      // Has a section but NO generated_at -> invalid (Phase K).
      '/snapshots/markets/US/dashboard.json':
          () => _json({'rotation': {'best_market': 'IDX'}}),
    });
    final repo = CdnRepository(svc, cache: cache);
    final res = await repo.sync(Market.us);
    expect(res.changed, isFalse);
    final stored = cache.read<Map>(SnapshotKeys.dashboard(Market.us))!;
    expect((stored['rotation'] as Map)['best_market'], 'US');
  });

  // === Inspector metadata =================================================
  test('localManifestVersion and lastCdnSync are persisted', () async {
    final dash = _dashboard(best: 'INDIA');
    final cache = CacheService.inMemory();
    final svc = _service({
      '/snapshots/manifest.json':
          () => _json(_manifest(version: 'v2026', dashHash: _sha(dash))),
      '/snapshots/markets/US/dashboard.json': () => _json(dash),
    });
    final repo = CdnRepository(svc, cache: cache);
    expect(repo.localManifestVersion, isNull);
    expect(repo.lastCdnSync, isNull);

    await repo.sync(Market.us);
    expect(repo.localManifestVersion, 'v2026');
    expect(repo.lastCdnSync, isNotNull);
    expect(repo.localManifest!.markets['US'], isNotEmpty);
  });
}
