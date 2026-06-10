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
}
