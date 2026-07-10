import 'package:flutter_test/flutter_test.dart';
import 'package:tradewiz/models/momentum.dart';

void main() {
  group('MomentumRebalanceSchedule parsing', () {
    test('parses an upcoming schedule from /momentum/picks payload', () {
      final p = MomentumPicks.fromJson({
        'picks': const [],
        'universe_size': 300,
        'tradable_size': 250,
        'top_n': 10,
        'regime': 'bull',
        'regime_note': 'ok',
        'stage': 'backtest-oos',
        'disclaimer': 'experimental',
        'generated_at': '2026-07-10T00:00:00Z',
        'rebalance': {
          'status': 'upcoming',
          'last_rebalance_date': '2026-07-06',
          'due_date': '2026-08-04',
          'trading_days_remaining': 17,
          'note': 'Next monthly rebalance in ~17 trading days.',
        },
      });
      expect(p.rebalance.status, 'upcoming');
      expect(p.rebalance.isDue, isFalse);
      expect(p.rebalance.hasClock, isTrue);
      expect(p.rebalance.dueDate, '2026-08-04');
      expect(p.rebalance.tradingDaysRemaining, 17);
    });

    test('flags a due rebalance', () {
      final p = MomentumPicks.fromJson({
        'picks': const [],
        'universe_size': 0,
        'tradable_size': 0,
        'top_n': 10,
        'regime': 'unknown',
        'regime_note': '',
        'stage': '',
        'disclaimer': '',
        'generated_at': '',
        'rebalance': {
          'status': 'due',
          'last_rebalance_date': '2026-06-01',
          'due_date': '2026-07-01',
          'trading_days_remaining': -3,
          'note': 'Monthly rebalance is due.',
        },
      });
      expect(p.rebalance.isDue, isTrue);
      expect(p.rebalance.tradingDaysRemaining, -3);
    });

    test('missing rebalance field defaults to no-clock (none)', () {
      final p = MomentumPicks.fromJson({
        'picks': const [],
        'universe_size': 0,
        'tradable_size': 0,
        'top_n': 10,
        'regime': 'unknown',
        'regime_note': '',
        'stage': '',
        'disclaimer': '',
        'generated_at': '',
      });
      expect(p.rebalance.status, 'none');
      expect(p.rebalance.hasClock, isFalse);
      expect(p.rebalance.dueDate, isNull);
    });
  });
}
