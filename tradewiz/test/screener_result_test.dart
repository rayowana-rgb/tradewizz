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
}
