import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/screener_result.dart';

void main() {
  Map<String, dynamic> baseJson() => {
        'market': 'IDX',
        'matches': [
          {
            'symbol': 'BBCA',
            'name': 'Bank Central Asia',
            'score': 90,
            'signal': 'BUY',
            'price': 9850,
            'change_percent': 1.2,
            'categories': ['bullish'],
          }
        ],
        'generated_at': '2026-06-04T00:00:00Z',
      };

  test('parses pagination metadata when present', () {
    final json = baseJson()
      ..addAll({
        'total_count': 42,
        'returned_count': 1,
        'limit': 50,
        'min_score': 70.0,
        'categories': ['bullish', 'scalping'],
      });
    final r = ScreenerResult.fromJson(json);
    expect(r.totalCount, 42);
    expect(r.returnedCount, 1);
    expect(r.limit, 50);
    expect(r.minScore, 70.0);
    expect(r.categories, ['bullish', 'scalping']);
    expect(r.hasMore, isTrue);
    expect(r.shownCount, 1);
  });

  test('backward compatible when metadata is missing', () {
    final r = ScreenerResult.fromJson(baseJson());
    expect(r.totalCount, isNull);
    expect(r.returnedCount, isNull);
    expect(r.limit, isNull);
    expect(r.minScore, isNull);
    expect(r.categories, isEmpty);
    // hasMore must be false (not throw) and shownCount falls back to matches.
    expect(r.hasMore, isFalse);
    expect(r.shownCount, 1);
  });

  test('hasMore is false when returned == total', () {
    final json = baseJson()
      ..addAll({'total_count': 1, 'returned_count': 1});
    expect(ScreenerResult.fromJson(json).hasMore, isFalse);
  });

  // --- Phase 9A: Explore intelligence overlay --------------------------- //
  test('parses Explore overlay fields when present', () {
    final json = baseJson();
    (json['matches'] as List).first.addAll({
      'base_score': 70.0,
      'category_bonus': 15,
      'conviction_score': 18,
      'final_score': 100.0,
      'explore_tags': ['Silent Accumulation', 'Strong CMF', 'Strong OBV'],
    });
    final m = ScreenerResult.fromJson(json).matches.first;
    expect(m.baseScore, 70.0);
    expect(m.categoryBonus, 15);
    expect(m.convictionScore, 18);
    expect(m.finalScore, 100.0);
    expect(m.exploreTags,
        ['Silent Accumulation', 'Strong CMF', 'Strong OBV']);
    expect(m.effectiveFinalScore, 100.0);
    expect(m.effectiveBaseScore, 70.0);
  });

  test('Explore overlay is backward compatible (old server)', () {
    // baseJson() has no overlay fields -> safe defaults, no throw.
    final m = ScreenerResult.fromJson(baseJson()).matches.first;
    expect(m.baseScore, isNull);
    expect(m.finalScore, isNull);
    expect(m.categoryBonus, 0);
    expect(m.convictionScore, 0);
    expect(m.exploreTags, isEmpty);
    // Effective getters fall back to the Base Score.
    expect(m.effectiveFinalScore, m.score);
    expect(m.effectiveBaseScore, m.score);
  });

  // --- Phase 11B: liquidity-first participation fields ------------------
  test('parses Phase 11B liquidity participation fields', () {
    final json = baseJson();
    (json['matches'] as List).first.addAll({
      'base_score': 74,
      'category_bonus': 5,
      'conviction_score': 10,
      'final_score': 92,
      'liquidity_score': 88.0,
      'participation_score': 88.0,
      'value_traded_today': 82000000000.0,
      'avg_value_traded_20d': 55000000000.0,
      'volume_today': 9000000.0,
      'avg_volume_20d': 3700000.0,
      'volume_ratio_20d': 2.4,
      'value_traded_ratio_20d': 1.5,
    });
    final m = ScreenerResult.fromJson(json).matches.first;
    expect(m.liquidityScore, 88.0);
    expect(m.participationScore, 88.0);
    expect(m.valueTradedToday, 82000000000.0);
    expect(m.avgValueTraded20d, 55000000000.0);
    expect(m.volumeToday, 9000000.0);
    expect(m.avgVolume20d, 3700000.0);
    expect(m.volumeRatio20d, 2.4);
    expect(m.valueTradedRatio20d, 1.5);
    expect(m.hasLiquidityBreakdown, isTrue);
    // Final Score remains the hero metric.
    expect(m.effectiveFinalScore, 92.0);
  });

  test('liquidity fields are backward compatible (old snapshot)', () {
    // baseJson() omits the Phase 11B fields -> null, no breakdown, no throw.
    final m = ScreenerResult.fromJson(baseJson()).matches.first;
    expect(m.liquidityScore, isNull);
    expect(m.participationScore, isNull);
    expect(m.valueTradedToday, isNull);
    expect(m.avgValueTraded20d, isNull);
    expect(m.volumeRatio20d, isNull);
    expect(m.hasLiquidityBreakdown, isFalse);
  });
}
