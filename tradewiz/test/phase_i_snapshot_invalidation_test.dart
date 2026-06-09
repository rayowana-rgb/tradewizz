import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/cache/cache_service.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/snapshot/snapshot_keys.dart';
import 'package:tradewiz/snapshot/snapshot_repository.dart';

void main() {
  test('current snapshot keys are namespaced by scoring schema version', () {
    expect(SnapshotKeys.scoringSchemaVersion, isNotEmpty);
    expect(
      SnapshotKeys.dashboard(Market.idx),
      contains(SnapshotKeys.scoringSchemaVersion),
    );
    expect(
      SnapshotKeys.portfolio,
      contains(SnapshotKeys.scoringSchemaVersion),
    );
    expect(
      SnapshotKeys.watchlist(Market.idx),
      contains(SnapshotKeys.scoringSchemaVersion),
    );
  });

  test('a snapshot stored under an OLD scoring version is not reused', () async {
    final cache = CacheService.inMemory();

    // Simulate a pre-fix snapshot: an illiquid stock with a bogus 95 score,
    // written under the *previous* key namespace (no current version).
    const oldKey = 'dashboard_snapshot_IDX'; // pre-Phase-I key shape
    await cache.write(oldKey, {
      'generated_at': '2026-06-01T00:00:00Z',
      'market': 'IDX',
      'daily_picks': {
        'title': 't',
        'date': 'd',
        'picks': [
          {
            'rank': 1,
            'symbol': 'PUMP',
            'market': 'IDX',
            'name': 'Illiquid Pump',
            'score': 95,
            'signal': 'BUY',
            'recommendation': 'stale bad score',
          }
        ],
      },
    }, ttl: const Duration(days: 365));

    final repo = SnapshotRepository(StockRepository(), cache: cache);
    // peekDashboard reads the CURRENT (versioned) key, which has no entry, so
    // the stale "95 BUY illiquid" snapshot can never resurface on Home.
    final peeked = repo.peekDashboard(Market.idx);
    expect(peeked, isNull);

    // The current key is genuinely different from the old one.
    expect(SnapshotKeys.dashboard(Market.idx), isNot(oldKey));
  });
}
