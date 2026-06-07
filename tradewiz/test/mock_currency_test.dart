import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';

import 'helpers.dart';

/// The offline repository forces the mock-fallback path; analyze() then returns
/// the mock-generated highlights. These assert the fallback formatting is
/// currency-aware per market and still includes every required field.
void main() {
  Future<List<String>> mockHighlights(Market market) async {
    final repo = offlineRepository();
    final res = await repo.analyze('TEST', market);
    expect(res.source.name, 'fallback'); // confirm we're on the mock path
    return res.data.highlights;
  }

  void expectAllFields(List<String> hl) {
    final text = hl.join(' | ');
    for (final label in [
      'Market Status',
      'Current Price',
      '20-Day Average Price',
      "Today's Volume",
      '20-Day Average Volume',
      'Value Traded Today',
      'Volume Ratio',
      'ATR',
    ]) {
      expect(text, contains(label), reason: 'missing "$label"');
    }
  }

  String priceLine(List<String> hl) =>
      hl.firstWhere((h) => h.startsWith('Current Price:'));
  String valueLine(List<String> hl) =>
      hl.firstWhere((h) => h.startsWith('Value Traded Today:'));

  test('IDX mock uses Rp', () async {
    final hl = await mockHighlights(Market.idx);
    expectAllFields(hl);
    expect(priceLine(hl), contains('Rp'));
    expect(valueLine(hl), contains('Rp'));
    expect(priceLine(hl), isNot(contains('HK\$')));
    expect(priceLine(hl), isNot(contains('\u20a9')));
  });

  test('HKEX mock uses HK\$', () async {
    final hl = await mockHighlights(Market.hkex);
    expectAllFields(hl);
    expect(priceLine(hl), contains('HK\$'));
    expect(valueLine(hl), contains('HK\$'));
    expect(priceLine(hl), isNot(contains('Rp')));
  });

  test('KOSPI mock uses won', () async {
    final hl = await mockHighlights(Market.kospi);
    expectAllFields(hl);
    expect(priceLine(hl), contains('\u20a9'));
    expect(valueLine(hl), contains('\u20a9'));
    expect(priceLine(hl), isNot(contains('Rp')));
  });

  test('KOSDAQ mock uses won', () async {
    final hl = await mockHighlights(Market.kosdaq);
    expectAllFields(hl);
    expect(priceLine(hl), contains('\u20a9'));
  });
}
