import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/ai_analysis_page.dart';
import 'package:tradewiz/widgets/market_selector.dart';

import 'helpers.dart';

/// Pump the analysis page, auto-run for [market], and settle.
Future<void> _analyze(WidgetTester tester, Market market) async {
  await tester.pumpWidget(
    wrapApp(
      AiAnalysisPage(
        market: market,
        initialSymbol: market == Market.idx
            ? 'BBCA'
            : market == Market.hkex
                ? '0700'
                : '005930',
        autoRun: true,
        repository: offlineRepository(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Market enum has correct Moomoo tradability flags', (_) async {
    expect(Market.hkex.tradableViaMoomoo, isTrue);
    expect(Market.idx.tradableViaMoomoo, isFalse);
    expect(Market.kospi.tradableViaMoomoo, isFalse);
    expect(Market.kosdaq.tradableViaMoomoo, isFalse);
    // Yahoo suffixes.
    expect(Market.hkex.yahooSuffix, '.HK');
    expect(Market.kospi.yahooSuffix, '.KS');
    expect(Market.idx.yahooSuffix, '.JK');
  });

  testWidgets('Market dropdown contains IDX, HKEX, KOSPI (and KOSDAQ)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketSelector(
            selected: Market.idx,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.tap(find.byType(MarketSelector));
    await tester.pumpAndSettle();
    // The dropdown menu lists every market code.
    for (final code in ['IDX', 'HKEX', 'KOSPI', 'KOSDAQ']) {
      expect(find.text(code), findsWidgets);
    }
  });

  testWidgets('HKEX analysis detail shows simulated Buy / Sell',
      (tester) async {
    await _analyze(tester, Market.hkex);
    await tester.scrollUntilVisible(
      find.byKey(const Key('buy_button')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('buy_button')), findsOneWidget);
    expect(find.byKey(const Key('sell_button')), findsOneWidget);
  });

  testWidgets('IDX analysis detail shows simulated Buy / Sell (no broker)',
      (tester) async {
    await _analyze(tester, Market.idx);
    await tester.scrollUntilVisible(
      find.byKey(const Key('buy_button')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Simulated trading is offered for every market now.
    expect(find.byKey(const Key('buy_button')), findsOneWidget);
    expect(find.byKey(const Key('sell_button')), findsOneWidget);
    expect(find.textContaining('not tradable via Moomoo'), findsNothing);
  });

  testWidgets('KOSPI analysis detail shows simulated Buy / Sell (no broker)',
      (tester) async {
    await _analyze(tester, Market.kospi);
    await tester.scrollUntilVisible(
      find.byKey(const Key('buy_button')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('buy_button')), findsOneWidget);
    expect(find.byKey(const Key('sell_button')), findsOneWidget);
    expect(find.textContaining('not tradable via Moomoo'), findsNothing);
  });
}
