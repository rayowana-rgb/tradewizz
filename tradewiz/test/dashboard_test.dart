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

Map<String, dynamic> _overviewJson({
  String market = 'IDX',
  bool available = true,
  int advances = 120,
  int declines = 80,
  int unchanged = 10,
  double totalValueTraded = 12.5e12,
  String currency = 'IDR',
  bool foreign = true,
}) {
  if (!available) {
    return {
      'market': market,
      'available': false,
      'status': null,
      'breadth': {
        'advances': null,
        'declines': null,
        'unchanged': null,
        'total': null,
      },
      'total_value_traded': null,
      'currency': currency,
      'top_gainer': null,
      'top_loser': null,
      'foreign_flow':
          foreign ? {'available': false, 'net_value': null, 'currency': currency} : null,
      'updated_at': '2026-06-08T03:15:00Z',
    };
  }
  return {
    'market': market,
    'available': true,
    'status': 'OPEN',
    'breadth': {
      'advances': advances,
      'declines': declines,
      'unchanged': unchanged,
      'total': advances + declines + unchanged,
    },
    'total_value_traded': totalValueTraded,
    'currency': currency,
    'top_gainer': {
      'symbol': 'BBCA',
      'name': 'Bank Central Asia',
      'price': 9000.0,
      'change_percent': 5.2,
    },
    'top_loser': {
      'symbol': 'GOTO',
      'name': 'GoTo',
      'price': 80.0,
      'change_percent': -6.1,
    },
    'foreign_flow': foreign
        ? {'available': false, 'net_value': null, 'currency': currency}
        : null,
    'updated_at': '2026-06-08T03:15:00Z',
  };
}

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

/// Repository serving /screen, /market/indices and /market/overview.
StockRepository _repoWithIndices(
  List<Map<String, dynamic>> indices, {
  Map<String, dynamic>? overview,
}) {
  final ov = overview ?? _overviewJson();
  final live = MockClient((req) async {
    final path = req.url.path;
    if (path.contains('/market/overview/')) {
      return http.Response(
        jsonEncode(ov),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
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

/// Repository whose /market/indices AND /market/overview fail (500); /screen
/// still works.
StockRepository _repoIndicesFail() {
  final live = MockClient((req) async {
    if (req.url.path.contains('/market/overview/')) {
      return http.Response(
        jsonEncode({'detail': 'upstream error'}),
        500,
        headers: {'content-type': 'application/json'},
      );
    }
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

  // --- Market Overview --------------------------------------------------- //
  testWidgets('Dashboard renders market overview (breadth + movers + value)',
      (tester) async {
    final repo = _repoWithIndices(
      [
        _indexJson(
          symbol: '^JKSE', market: 'IDX', name: 'IHSG',
          price: 7250.55, change: 35.40, changePercent: 0.49,
        ),
      ],
      overview: _overviewJson(
        advances: 120, declines: 80, unchanged: 10,
        totalValueTraded: 12.5e12,
      ),
    );
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard_overview_card')), findsOneWidget);
    // Breadth values.
    expect(find.text('120'), findsOneWidget);
    expect(find.text('80'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    expect(find.text('Advances'), findsOneWidget);
    expect(find.text('Declines'), findsOneWidget);
    expect(find.text('Unchanged'), findsOneWidget);
    // Top gainer / loser.
    expect(find.text('BBCA'), findsOneWidget);
    expect(find.text('GOTO'), findsOneWidget);
    expect(find.text('Top Gainer'), findsOneWidget);
    expect(find.text('Top Loser'), findsOneWidget);
    // Total value traded (compact).
    expect(find.text('Value Traded'), findsOneWidget);
    expect(find.text('IDR 12.50T'), findsOneWidget);
  });

  testWidgets('Dashboard shows Foreign Flow row for IDX', (tester) async {
    final repo = _repoWithIndices(
      [
        _indexJson(
          symbol: '^JKSE', market: 'IDX', name: 'IHSG',
          price: 7250.55, change: 35.40, changePercent: 0.49,
        ),
      ],
      overview: _overviewJson(foreign: true),
    );
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Foreign Flow'), findsOneWidget);
    // No real source yet -> Unavailable, never a fake number.
    expect(find.byKey(const Key('dashboard_overview_foreign')), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('Dashboard hides Foreign Flow for non-IDX market',
      (tester) async {
    final repo = _repoWithIndices(
      [
        _indexJson(
          symbol: '^HSI', market: 'HKEX', name: 'Hang Seng',
          price: 19500.0, change: -120.0, changePercent: -0.61,
        ),
      ],
      overview: _overviewJson(
          market: 'HKEX', currency: 'HKD', foreign: false),
    );
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.hkex),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Foreign Flow'), findsNothing);
  });

  testWidgets('Dashboard shows overview unavailable on backend failure',
      (tester) async {
    final repo = _repoIndicesFail();
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard_overview_unavailable')),
        findsOneWidget);
    expect(find.text('Market overview unavailable'), findsOneWidget);
    expect(find.byKey(const Key('dashboard_overview_card')), findsNothing);
  });

  testWidgets('Dashboard shows overview unavailable when backend has no data',
      (tester) async {
    final repo = _repoWithIndices(
      [
        _indexJson(
          symbol: '^JKSE', market: 'IDX', name: 'IHSG',
          price: 7250.55, change: 35.40, changePercent: 0.49,
        ),
      ],
      overview: _overviewJson(available: false),
    );
    await tester.pumpWidget(wrapApp(
      const DashboardPage(market: Market.idx),
      repository: repo,
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dashboard_overview_unavailable')),
        findsOneWidget);
  });
}
