import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_entry.dart';
import 'package:tradewiz/cache/cache_keys.dart';
import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/cache/cached_repository.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';

// --- test plumbing ----------------------------------------------------------

/// A mock client whose response handler can be swapped mid-test (to simulate
/// the backend going down after a first successful fetch).
class _SwitchableBackend {
  _SwitchableBackend(this.handler);
  Future<http.Response> Function(http.Request req) handler;

  StockRepository repo() => StockRepository(
        client: ApiClient(
          config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
          httpClient: MockClient((req) => handler(req)),
        ),
      );
}

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _briefJson({String headline = 'Live headline'}) => {
      'market': 'US',
      'title': 'AI Morning Brief',
      'market_regime': 'BULL',
      'strongest_sector': 'Tech',
      'headline': headline,
      'notes': const [],
    };

Map<String, dynamic> _rotationJson({String best = 'US'}) => {
      'best_market': best,
      'rotation_summary': 'Rotate into $best',
      'markets': [
        {
          'market': best,
          'rank': 1,
          'rotation_score': 88.0,
          'recommendation': 'OVERWEIGHT',
        },
      ],
    };

Map<String, dynamic> _indicesJson(List<Map<String, dynamic>> items) =>
    {'indices': items};

Map<String, dynamic> _indexItem({double? price}) => {
      'symbol': '^GSPC',
      'market': 'US',
      'name': 'S&P 500',
      'currency': 'USD',
      'price': price,
      'change': 10.0,
      'change_percent': 0.5,
      'status': 'OPEN',
      'available': price != null,
    };

void main() {
  const token = 'tok';

  // === Cache Service: save / load / expiry / stale ========================
  group('CacheService', () {
    test('save then load returns the payload', () async {
      final c = CacheService.inMemory();
      await c.write('k', {'a': 1}, ttl: const Duration(minutes: 5));
      expect(c.read<Map>('k'), {'a': 1});
      expect(c.has('k'), isTrue);
    });

    test('expiry: stale entries are flagged and rejected when not allowed',
        () async {
      final c = CacheService.inMemory();
      // Write with a zero TTL so it is immediately past expiry.
      await c.write('k', 42, ttl: Duration.zero);
      // Allow a microtask so DateTime.now() moves past expiresAt.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(c.isStale('k'), isTrue);
      // Stale allowed (default): still returned for SWR/offline.
      expect(c.read<int>('k'), 42);
      // Stale rejected: caller wants only fresh.
      expect(c.read<int>('k', allowStale: false), isNull);
    });

    test('stale detection: fresh entry is not stale', () async {
      final c = CacheService.inMemory();
      await c.write('k', 1, ttl: const Duration(minutes: 5));
      expect(c.isStale('k'), isFalse);
      final entry = c.readEntry('k')!;
      expect(entry.stale, isFalse);
      expect(entry.isFreshAt(DateTime.now()), isTrue);
    });

    test('remove / clearAll', () async {
      final c = CacheService.inMemory();
      await c.write('a', 1, ttl: const Duration(minutes: 5));
      await c.write('b', 2, ttl: const Duration(minutes: 5));
      await c.remove('a');
      expect(c.has('a'), isFalse);
      expect(c.has('b'), isTrue);
      await c.clearAll();
      expect(c.keys(), isEmpty);
    });

    test('stats expose age, ttl and stale for the inspector', () async {
      final c = CacheService.inMemory();
      await c.write(CacheKeys.globalRotation, _rotationJson(),
          ttl: CacheKeys.ttlGlobalRotation);
      final stats = c.stats();
      expect(stats, hasLength(1));
      expect(stats.first.label, 'Rotation');
      expect(stats.first.ttl, CacheKeys.ttlGlobalRotation);
      expect(stats.first.stale, isFalse);
    });
  });

  // === Morning Brief: first load network, second load cache ===============
  group('Morning Brief cache', () {
    test('first load hits network, second load served from cache', () async {
      var calls = 0;
      final backend = _SwitchableBackend((req) async {
        if (req.url.path.endsWith('/morning-brief/US')) {
          calls++;
          return _json(_briefJson());
        }
        return http.Response('nf', 404);
      });
      final cache = CacheService.inMemory();
      final repo = CachedRepository(backend.repo(), cache: cache);

      final first = await repo.morningBrief(token, Market.us);
      expect(first.isCached, isFalse);
      expect(first.value.headline, 'Live headline');
      expect(calls, 1);

      // Take the backend "down": a cached value must still be returned.
      backend.handler = (req) async => http.Response('boom', 500);
      final second = await repo.morningBrief(token, Market.us);
      expect(second.value.headline, 'Live headline');
      expect(second.isCached, isTrue);
      expect(second.offline, isTrue);
      // Network was attempted but failed; cache served it.
      expect(calls, 1);
    });

    test('SWR stream emits cache first then fresh', () async {
      final cache = CacheService.inMemory();
      // Pre-seed a cached brief.
      await cache.write(CacheKeys.morningBrief(Market.us),
          _briefJson(headline: 'Cached headline'),
          ttl: CacheKeys.ttlMorningBrief);

      final backend = _SwitchableBackend((req) async => _json(
          _briefJson(headline: 'Fresh headline')));
      final repo = CachedRepository(backend.repo(), cache: cache);

      final emitted = await repo.morningBriefSwr(token, Market.us).toList();
      expect(emitted, hasLength(2));
      // 1) cache first
      expect(emitted[0].isCached, isTrue);
      expect(emitted[0].value.headline, 'Cached headline');
      // 2) fresh second (differs from cache)
      expect(emitted[1].isCached, isFalse);
      expect(emitted[1].value.headline, 'Fresh headline');
    });
  });

  // === Rotation: cache hit / cache expiry =================================
  group('Rotation cache', () {
    test('cache hit on second call (no second network round trip emitted)',
        () async {
      var calls = 0;
      final backend = _SwitchableBackend((req) async {
        calls++;
        return _json(_rotationJson(best: 'US'));
      });
      final cache = CacheService.inMemory();
      final repo = CachedRepository(backend.repo(), cache: cache);

      final r1 = await repo.globalRotation(token);
      expect(r1.value.bestMarket, 'US');
      expect(calls, 1);
      expect(cache.has(CacheKeys.globalRotation), isTrue);
      expect(cache.isStale(CacheKeys.globalRotation), isFalse);

      // A second SWR stream serves the fresh cache instantly. Even though SWR
      // also refreshes in the background, the cached value is what's shown
      // first (cache hit).
      final emitted = await repo.globalRotationSwr(token).toList();
      expect(emitted.first.isCached, isTrue);
      expect(emitted.first.value.bestMarket, 'US');
    });

    test('cache expiry: entry past TTL is flagged stale', () async {
      final cache = CacheService.inMemory();
      await cache.write(CacheKeys.globalRotation, _rotationJson(),
          ttl: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(cache.isStale(CacheKeys.globalRotation), isTrue);
      // Stale read still works for offline display.
      expect(cache.read<Map>(CacheKeys.globalRotation), isNotNull);
    });
  });

  // === Indices: network fail uses cache ==================================
  group('Indices cache', () {
    test('network fail falls back to cached indices (offline flagged)',
        () async {
      final backend = _SwitchableBackend(
          (req) async => _json(_indicesJson([_indexItem(price: 5000)])));
      final cache = CacheService.inMemory();
      final repo = CachedRepository(backend.repo(), cache: cache);

      final first = await repo.indices();
      expect(first.value.single.price, 5000);
      expect(first.offline, isFalse);

      backend.handler = (req) async => http.Response('down', 500);
      final second = await repo.indices();
      expect(second.value.single.price, 5000); // kept previous values
      expect(second.isCached, isTrue);
      expect(second.offline, isTrue);
    });

    test('never replaces valid cached data with an empty refresh', () async {
      final backend = _SwitchableBackend(
          (req) async => _json(_indicesJson([_indexItem(price: 4200)])));
      final cache = CacheService.inMemory();
      final repo = CachedRepository(backend.repo(), cache: cache);

      await repo.indicesSwr().toList(); // warms cache with 1 index

      // Backend now returns an EMPTY indices list.
      backend.handler = (req) async => _json(_indicesJson(const []));
      final emitted = await repo.indicesSwr().toList();
      // The last emitted value must still hold the previous non-empty data.
      expect(emitted.last.value, isNotEmpty);
      expect(emitted.last.value.single.price, 4200);
    });
  });

  // === Offline Mode: cached data shown, no blank screen ===================
  group('Offline mode', () {
    test('peek returns cached data without any network (offline)', () async {
      final cache = CacheService.inMemory();
      await cache.write(CacheKeys.globalRotation, _rotationJson(best: 'IDX'),
          ttl: CacheKeys.ttlGlobalRotation);
      final repo = CachedRepository(
        _SwitchableBackend((req) async => http.Response('down', 500)).repo(),
        cache: cache,
      );
      final peeked = repo.peek(CacheKeys.globalRotation,
          (raw) => (raw as Map)['best_market']);
      expect(peeked, isNotNull);
      expect(peeked!.value, 'IDX');
      expect(peeked.offline, isTrue);
    });

    test('with no cache and a dead backend the future surfaces an error',
        () async {
      final repo = CachedRepository(
        _SwitchableBackend((req) async => http.Response('down', 500)).repo(),
        cache: CacheService.inMemory(),
      );
      // No cache -> nothing to show -> error (UI renders an "unavailable"
      // state, never a blank screen).
      await expectLater(
          repo.globalRotation(token), throwsA(isA<ApiException>()));
    });
  });

  // === SWR: cache first, background refresh updates ======================
  group('SWR pattern', () {
    test('does not emit a duplicate when fresh equals cache', () async {
      final cache = CacheService.inMemory();
      await cache.write(CacheKeys.morningBrief(Market.us),
          _briefJson(headline: 'Same'),
          ttl: CacheKeys.ttlMorningBrief);
      final backend =
          _SwitchableBackend((req) async => _json(_briefJson(headline: 'Same')));
      final repo = CachedRepository(backend.repo(), cache: cache);

      final emitted = await repo.morningBriefSwr(token, Market.us).toList();
      // Cache and fresh are identical -> only the cached emission is yielded.
      expect(emitted, hasLength(1));
      expect(emitted.single.isCached, isTrue);
    });

    test('Cached.freshnessLabel reads naturally', () {
      final now = DateTime(2026, 1, 1, 12, 0);
      final fresh = Cached<int>(
          value: 1, isCached: false, lastUpdated: now);
      final cached = Cached<int>(
          value: 1, isCached: true, lastUpdated: now);
      final later = now.add(const Duration(minutes: 5));
      expect(fresh.freshnessLabel(now: later), 'Updated 5 min ago');
      expect(cached.freshnessLabel(now: later), 'Cached • 5 min ago');
    });
  });
}
