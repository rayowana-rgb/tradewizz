import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/dashboard_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';

import 'helpers.dart';

http.Response _screenOk() => http.Response(
      jsonEncode({
        'market': 'IDX',
        'matches': [
          {
            'symbol': 'BBCA',
            'name': 'Bank Central Asia',
            'score': 90.0,
            'signal': 'BUY',
            'price': 9000.0,
            'change_percent': 2.0,
            'categories': ['bullish'],
          },
        ],
        'generated_at': '2026-06-08T00:00:00Z',
        'total_count': 1,
        'returned_count': 1,
        'limit': 50,
        'min_score': 0,
        'categories': <String>[],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _indexJson({
  required String symbol,
  required String market,
  required String name,
  double? price,
  double? change,
  double? changePercent,
  String status = 'CLOSED',
  bool available = true,
}) =>
    {
      'symbol': symbol,
      'market': market,
      'name': name,
      'price': price,
      'change': change,
      'change_percent': changePercent,
      'currency': 'IDR',
      'status': status,
      'updated_at': '2026-06-08T03:15:00Z',
      'available': available,
    };

/// Repository serving /screen and /market/indices with real index numbers.
StockRepository _repoWithIndices(List<Map<String, dynamic>> indices) {
  final live = MockClient((req) async {
    final path = req.url.path;
    if (path.endsWith('/market/indices')) {
      return http.Response(
        jsonEncode({'indices': indices}),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (path.contains('/screen/')) return _screenOk();
    return http.Response('not found', 404);
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: live,
    ),
  );
}

/// Repository whose /market/indices fails (500); /screen still works.
StockRepository _repoIndicesFail() {
  final live = MockClient((req) async {
    if (req.url.path.endsWith('/market/indices')) {
      return http.Response(
        jsonEncode({'detail': 'upstream error'}),
        500,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path.contains('/screen/')) return _screenOk();
    return http.Response('not found', 404);
  });
  return StockRepository(
    client: ApiClient(
      config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
      httpClient: live,
    ),
  );
}

void main() {
  testWidgets('Dashboard renders real backend index data', (tester) async {
    final repo = _repoWithIndices([
      _indexJson(
        symbol: '^JKSE',
        market: 'IDX',
        name: 'IHSG',
        price: 7250.55,
        change: 35.40,
        changePercent: 0.49,
        status: 'OPEN',
      ),
    ]);
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    // Real index card present (not the unavailable state).
    expect(find.byKey(const Key('dashboard_index_card')), findsOneWidget);
    expect(find.byKey(const Key('dashboard_index_unavailable')), findsNothing);
    // Name, price, change %, status from the backend.
    expect(find.text('IHSG'), findsOneWidget);
    expect(find.text('7,250.55'), findsOneWidget);
    expect(find.byKey(const Key('dashboard_index_change')), findsOneWidget);
    expect(find.textContaining('0.49%'), findsOneWidget);
    expect(find.text('OPEN'), findsOneWidget);
  });

  testWidgets('Dashboard shows unavailable warning on backend failure',
      (tester) async {
    final repo = _repoIndicesFail();
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard_index_unavailable')), findsOneWidget);
    expect(find.text('Index data unavailable'), findsOneWidget);
    // No card with fabricated numbers.
    expect(find.byKey(const Key('dashboard_index_card')), findsNothing);
  });

  testWidgets('Dashboard shows unavailable when backend reports no data',
      (tester) async {
    // Backend reachable but available=false / null price -> still unavailable.
    final repo = _repoWithIndices([
      _indexJson(
        symbol: '^JKSE',
        market: 'IDX',
        name: 'IHSG',
        price: null,
        available: false,
      ),
    ]);
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard_index_unavailable')), findsOneWidget);
    expect(find.text('Index data unavailable'), findsOneWidget);
  });

  testWidgets('Dashboard does NOT show old hardcoded mock index values',
      (tester) async {
    final repo = _repoWithIndices([
      _indexJson(
        symbol: '^JKSE',
        market: 'IDX',
        name: 'IHSG',
        price: 7250.55,
        change: 35.40,
        changePercent: 0.49,
      ),
    ]);
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    // The removed hardcoded values must be gone.
    expect(find.text('+0.84%'), findsNothing);
    expect(find.text('IDX Comp.'), findsNothing);
  });

  testWidgets('Dashboard picks the index matching the selected market',
      (tester) async {
    final repo = _repoWithIndices([
      _indexJson(
        symbol: '^JKSE',
        market: 'IDX',
        name: 'IHSG',
        price: 7250.55,
        change: 35.40,
        changePercent: 0.49,
      ),
      _indexJson(
        symbol: '^HSI',
        market: 'HKEX',
        name: 'Hang Seng',
        price: 19500.0,
        change: -120.0,
        changePercent: -0.61,
      ),
    ]);
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.hkex),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    // HKEX selected -> Hang Seng index shown, not IHSG.
    expect(find.text('Hang Seng'), findsOneWidget);
    expect(find.text('IHSG'), findsNothing);
    expect(find.text('19,500.00'), findsOneWidget);
  });
}
