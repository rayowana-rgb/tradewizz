import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/screener_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/widgets/connection_pill.dart';

import 'helpers.dart';

StockRepository _liveRepo() {
  final live = MockClient((req) async {
    return http.Response(
      jsonEncode({
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
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: live,
    ),
  );
}

void main() {
  testWidgets('Screener shows Live pill when backend responds', (tester) async {
    await tester.pumpWidget(
      wrapApp(
        ScreenerPage(market: Market.idx, repository: _liveRepo()),
        repository: _liveRepo(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionPill), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
  });

  testWidgets('Screener shows Mock pill when backend is unreachable',
      (tester) async {
    await tester.pumpWidget(
      wrapApp(
        ScreenerPage(market: Market.idx, repository: offlineRepository()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mock'), findsOneWidget);
  });

  testWidgets('Degraded banner exposes a working Retry action',
      (tester) async {
    var calls = 0;
    final flaky = MockClient((req) async {
      calls++;
      throw http.ClientException('offline');
    });
    final repo = StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: flaky,
      ),
    );

    await tester.pumpWidget(
      wrapApp(ScreenerPage(market: Market.idx, repository: repo)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Mock'), findsOneWidget);
    final afterInitial = calls;
    expect(afterInitial, greaterThan(0));

    // Tap Retry on the banner -> triggers another fetch attempt.
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(calls, greaterThan(afterInitial));
    expect(find.text('Mock'), findsOneWidget);
  });
}
