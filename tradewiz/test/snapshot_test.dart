import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/snapshot/snapshot_keys.dart';
import 'package:tradewiz/snapshot/snapshot_models.dart';
import 'package:tradewiz/snapshot/snapshot_repository.dart';

class _Backend {
  _Backend(this.handler);
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

Map<String, dynamic> _dashboard({String best = 'US', String headline = 'Hi'}) =>
    {
      'generated_at': '2026-06-09T12:00:00Z',
      'market': 'US',
      'indices': {
        'indices': [
          {
            'symbol': '^GSPC',
            'market': 'US',
            'name': 'S&P 500',
            'price': 5000.0,
            'change': 10.0,
            'change_percent': 0.2,
            'status': 'OPEN',
            'available': true,
          }
        ]
      },
      'morning_brief': {'market': 'US', 'headline': headline, 'notes': []},
      'rotation': {'best_market': best, 'markets': []},
      'radar': {'opportunities': []},
      'daily_picks': {'picks': []},
      'multibagger': {'candidates': []},
      'watchlist_ai': {'suggestions': []},
      'notifications': {'notifications': [], 'unread_count': 0},
      'section_ages': {'indices': 1.0, 'rotation': 2.0},
    };

const token = 'tok';

void main() {
  // === Phase F/G: model parsing ===========================================
  group('Snapshot models', () {
    test('DashboardSnapshot parses every section via existing fromJson', () {
      final s = DashboardSnapshot(_dashboard(), market: Market.us);
      expect(s.market, Market.us);
      expect(s.indices.single.price, 5000.0);
      expect(s.morningBrief!.headline, 'Hi');
      expect(s.rotation!.bestMarket, 'US');
      expect(s.notifications!.unreadCount, 0);
      expect(s.sectionAges['indices'], 1.0);
      expect(s.generatedAt, isNotNull);
    });

    test('null sections degrade to null/empty, never throw', () {
      final s = DashboardSnapshot({'market': 'US'}, market: Market.us);
      expect(s.indices, isEmpty);
      expect(s.morningBrief, isNull);
      expect(s.rotation, isNull);
      expect(s.notifications, isNull);
    });

    test('PortfolioSnapshot exposes account/positions/health', () {
      final p = PortfolioSnapshot({
        'generated_at': '2026-06-09T12:00:00Z',
        'account': {'cash': 1000.0},
        'positions': [
          {'symbol': 'NVDA'}
        ],
        'portfolio_quality': [
          {'symbol': 'NVDA', 'grade': 'A'}
        ],
      });
      expect(p.account!['cash'], 1000.0);
      expect(p.positions.single['symbol'], 'NVDA');
      expect(p.portfolioQuality.single['grade'], 'A');
    });
  });

  // === Phase H/I: SWR cache-first then fresh ===============================
  group('SnapshotRepository SWR', () {
    test('first call hits network and stores the snapshot in Hive', () async {
      var calls = 0;
      final backend = _Backend((req) async {
        calls++;
        return _json(_dashboard(best: 'US'));
      });
      final cache = CacheService.inMemory();
      final repo = SnapshotRepository(backend.repo(), cache: cache);

      final first = await repo.fetchDashboardSnapshot(token, Market.us);
      expect(first.isCached, isFalse);
      expect(first.value.rotation!.bestMarket, 'US');
      expect(calls, 1);
      expect(cache.has(SnapshotKeys.dashboard(Market.us)), isTrue);
    });

    test('emits cache first then fresh when they differ', () async {
      final cache = CacheService.inMemory();
      await cache.write(SnapshotKeys.dashboard(Market.us),
          _dashboard(best: 'IDX'), ttl: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      final backend = _Backend((req) async => _json(_dashboard(best: 'US')));
      final repo = SnapshotRepository(backend.repo(), cache: cache);

      final emitted =
          await repo.dashboardSwr(token, Market.us).toList();
      expect(emitted, hasLength(2));
      expect(emitted[0].isCached, isTrue);
      expect(emitted[0].value.rotation!.bestMarket, 'IDX');
      expect(emitted[1].isCached, isFalse);
      expect(emitted[1].value.rotation!.bestMarket, 'US');
    });

    test('fresh cache short-circuits the network (cache hit)', () async {
      var calls = 0;
      final cache = CacheService.inMemory();
      await cache.write(SnapshotKeys.dashboard(Market.us),
          _dashboard(best: 'US'), ttl: const Duration(minutes: 5));
      final backend = _Backend((req) async {
        calls++;
        return _json(_dashboard(best: 'US'));
      });
      final repo = SnapshotRepository(backend.repo(), cache: cache);

      final emitted = await repo.dashboardSwr(token, Market.us).toList();
      expect(emitted, hasLength(1));
      expect(emitted.single.isCached, isTrue);
      expect(calls, 0); // never hit the network
    });
  });

  // === Phase J: offline mode ==============================================
  group('Offline mode', () {
    test('network failure keeps cached snapshot + flags offline', () async {
      final cache = CacheService.inMemory();
      // Seed a stale snapshot so a refresh is attempted.
      await cache.write(SnapshotKeys.dashboard(Market.us),
          _dashboard(best: 'US'), ttl: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      final backend = _Backend((req) async => http.Response('down', 500));
      final repo = SnapshotRepository(backend.repo(), cache: cache);

      final last = await repo.fetchDashboardSnapshot(token, Market.us);
      expect(last.isCached, isTrue);
      expect(last.offline, isTrue);
      expect(last.value.rotation!.bestMarket, 'US');
      expect(repo.metrics.offlineLoadCount, greaterThan(0));
    });

    test('peek returns cached snapshot with no network', () {
      final cache = CacheService.inMemory();
      cache.write(SnapshotKeys.portfolio, {
        'generated_at': '2026-06-09T12:00:00Z',
        'account': {'cash': 5.0},
        'positions': [],
      }, ttl: SnapshotKeys.portfolioTtl);
      final repo = SnapshotRepository(
        _Backend((req) async => http.Response('x', 500)).repo(),
        cache: cache,
      );
      final peeked = repo.peekPortfolio();
      expect(peeked, isNotNull);
      expect(peeked!.account!['cash'], 5.0);
    });

    test('no cache + dead backend surfaces an error (never blank)', () async {
      final repo = SnapshotRepository(
        _Backend((req) async => http.Response('down', 500)).repo(),
        cache: CacheService.inMemory(),
      );
      await expectLater(
        repo.fetchDashboardSnapshot(token, Market.us),
        throwsA(isA<ApiException>()),
      );
    });
  });

  // === Phase N: reliability ===============================================
  group('Reliability', () {
    test('empty refresh never overwrites a valid snapshot', () async {
      final cache = CacheService.inMemory();
      await cache.write(SnapshotKeys.dashboard(Market.us),
          _dashboard(best: 'US'), ttl: Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 2));

      // Backend returns an empty document.
      final backend = _Backend((req) async => _json(<String, dynamic>{}));
      final repo = SnapshotRepository(backend.repo(), cache: cache);

      await repo.dashboardSwr(token, Market.us).toList();
      // Stored snapshot is still the previous good one.
      final stored = cache.read<Map>(SnapshotKeys.dashboard(Market.us))!;
      expect((stored['rotation'] as Map)['best_market'], 'US');
    });
  });

  // === Phase K: force refresh =============================================
  test('force refresh re-fetches even when cache is fresh', () async {
    var calls = 0;
    final cache = CacheService.inMemory();
    await cache.write(SnapshotKeys.dashboard(Market.us),
        _dashboard(best: 'US'), ttl: const Duration(minutes: 5));
    final backend = _Backend((req) async {
      calls++;
      expect(req.url.query, contains('force=true'));
      return _json(_dashboard(best: 'JAPAN'));
    });
    final repo = SnapshotRepository(backend.repo(), cache: cache);

    final last =
        await repo.fetchDashboardSnapshot(token, Market.us, force: true);
    expect(calls, 1);
    expect(last.value.rotation!.bestMarket, 'JAPAN');
  });

  // === Phase M: metrics ===================================================
  test('metrics track hit / miss / success / failure', () async {
    final cache = CacheService.inMemory();
    final backend = _Backend((req) async => _json(_dashboard()));
    final repo = SnapshotRepository(backend.repo(), cache: cache);

    // miss + refresh success
    await repo.fetchDashboardSnapshot(token, Market.us);
    expect(repo.metrics.cacheMissCount, 1);
    expect(repo.metrics.refreshSuccessCount, 1);

    final map = repo.metrics.toMap();
    expect(map.containsKey('snapshot_load_time'), isTrue);
    expect(map['cache_miss'], 1);
  });
}
