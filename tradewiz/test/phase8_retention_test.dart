import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/home/retention_notifications.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/snapshot/snapshot_models.dart';

DashboardSnapshot _snap({
  String symbol = 'BBCA',
  String signal = 'BUY',
  double score = 90,
}) =>
    DashboardSnapshot({
      'generated_at': '2026-06-09T08:00:00Z',
      'daily_picks': {
        'title': 't',
        'date': 'd',
        'picks': [
          {
            'rank': 1,
            'symbol': symbol,
            'market': 'IDX',
            'name': 'X',
            'score': score,
            'signal': signal,
            'recommendation': 'Accumulation detected.',
          }
        ],
      },
    }, market: Market.idx);

void main() {
  test('watchlist symbol with a BUY signal wins the push', () {
    final push = RetentionNotifications.forSnapshot(
      _snap(symbol: 'BBCA', signal: 'BUY'),
      watchlist: ['BBCA'],
    );
    expect(push.title, contains('BBCA'));
    expect(push.title.toLowerCase(), contains('buy signal'));
  });

  test('positive watchlist change is surfaced when no buy signal', () {
    final push = RetentionNotifications.forSnapshot(
      _snap(symbol: 'XYZ', signal: 'HOLD'),
      watchlist: ['BBCA'],
      watchlistChangePct: 2.3,
    );
    expect(push.title, contains('+2.3%'));
  });

  test('strong new idea is surfaced as entering Today\'s Ideas', () {
    final push = RetentionNotifications.forSnapshot(
      _snap(symbol: 'NVDA', signal: 'HOLD', score: 95),
    );
    expect(push.title, contains('NVDA'));
    expect(push.title, contains("Today's Ideas"));
  });

  test('falls back to the generic morning-brief nudge', () {
    final push = RetentionNotifications.forSnapshot(
      _snap(symbol: 'ABC', signal: 'HOLD', score: 50),
    );
    expect(push.title, RetentionNotifications.morningBriefReady.title);
  });
}
