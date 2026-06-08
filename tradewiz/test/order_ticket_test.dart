import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/broker.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/models/user.dart';
import 'package:tradewiz/pages/order_ticket_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/auth_scope.dart';
import 'package:tradewiz/services/auth_store.dart';

/// Fake SIMULATION backend. Records calls + payloads so tests can assert that
/// the ticket calls /v1/sim/order/* (never a broker endpoint), that preview
/// does not place, and that every response is marked simulated.
class _FakeSim {
  _FakeSim({this.placeStatus = 200, this.placeDetail});

  final List<String> calls = [];
  final List<String?> bearers = [];
  final List<String?> previewMarkets = [];
  final List<String?> placeMarkets = [];

  final int placeStatus;
  final String? placeDetail;

  http.Response handle(http.Request req) {
    calls.add('${req.method} ${req.url.path}');
    bearers.add(req.headers['Authorization']);
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.url.path.endsWith('/sim/order/preview')) {
      previewMarkets.add(body['market'] as String?);
      final qty = (body['quantity'] as num?) ?? 0;
      final price = (body['price'] as num?) ?? 100;
      return http.Response(
        jsonEncode({
          'symbol': body['symbol'],
          'market': body['market'],
          'side': body['side'],
          'quantity': qty,
          'order_type': body['order_type'],
          'price': price,
          'estimated_value': qty * price,
          'currency': 'USD',
          'cash_after': 1000000 - qty * price,
          'simulated': true,
          'warning': 'Simulation only. No real broker order will be sent.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path.endsWith('/sim/order/place')) {
      placeMarkets.add(body['market'] as String?);
      if (placeStatus != 200) {
        return http.Response(
          jsonEncode({'detail': placeDetail}),
          placeStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      final qty = (body['quantity'] as num?) ?? 0;
      final price = (body['price'] as num?) ?? 100;
      return http.Response(
        jsonEncode({
          'order_id': 'SIM-ABC123',
          'symbol': body['symbol'],
          'market': body['market'],
          'side': body['side'],
          'quantity': qty,
          'price': price,
          'value': qty * price,
          'status': 'FILLED_SIMULATED',
          'realized_pnl': 0,
          'cash_after': 1000000 - qty * price,
          'simulated': true,
          'message': 'Simulated order filled. No real broker order was sent.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not found', 404);
  }
}

StockRepository _repo(_FakeSim sim) => StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async => sim.handle(req)),
      ),
    );

AuthStore _loggedInStore() {
  final store = AuthStore();
  store.setSession(
    'JWT-TEST',
    const UserProfile(
      id: 1,
      email: 'trader@x.com',
      createdAt: '2026-06-08T00:00:00Z',
      updatedAt: '2026-06-08T00:00:00Z',
    ),
  );
  return store;
}

Widget _wrap(Widget child) => AuthScope(
      store: _loggedInStore(),
      child: MaterialApp(home: child),
    );

/// Default order type is Market -> only quantity is needed to preview.
Future<void> _fillAndPreview(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('qty_field')), '100');
  await tester.tap(find.byKey(const Key('preview_order_button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Order ticket shows the simulation warning banner up front',
      (tester) async {
    final sim = _FakeSim();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'AAPL',
      market: Market.us,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));
    expect(find.byKey(const Key('sim_warning_banner')), findsOneWidget);
    expect(
      find.text('Simulation mode only. This does not place a real trade.'),
      findsOneWidget,
    );
  });

  testWidgets('Preview calls /v1/sim/order/preview and does NOT place',
      (tester) async {
    final sim = _FakeSim();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'AAPL',
      market: Market.us,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));

    await _fillAndPreview(tester);

    expect(find.text('Simulated Order Preview'), findsOneWidget);
    expect(sim.calls, ['POST /v1/sim/order/preview']);
    expect(sim.calls.any((c) => c.contains('broker')), isFalse);
    expect(sim.calls.any((c) => c.contains('ibkr')), isFalse);
    expect(sim.bearers.first, 'Bearer JWT-TEST');
  });

  testWidgets('Confirm places a simulated order via /v1/sim/order/place',
      (tester) async {
    final sim = _FakeSim();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'AAPL',
      market: Market.us,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));

    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sim_result_title')), findsOneWidget);
    expect(find.text('Simulated order filled'), findsOneWidget);
    expect(
      find.text('Simulated order filled. No real broker order was sent.'),
      findsOneWidget,
    );
    expect(sim.calls, [
      'POST /v1/sim/order/preview',
      'POST /v1/sim/order/place',
    ]);
    // Only sim endpoints — never a broker/ibkr/moomoo endpoint.
    for (final c in sim.calls) {
      expect(c.contains('broker'), isFalse);
      expect(c.contains('ibkr'), isFalse);
      expect(c.contains('moomoo'), isFalse);
    }
  });

  testWidgets('Works for a market with no broker (IDX) — simulated', (tester) async {
    final sim = _FakeSim();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'BBCA',
      market: Market.idx,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));
    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(sim.previewMarkets, ['IDX']);
    expect(sim.placeMarkets, ['IDX']);
    expect(find.text('Simulated order filled'), findsOneWidget);
  });

  testWidgets('SIMULATED chip + warning are shown on the preview',
      (tester) async {
    final sim = _FakeSim();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'AAPL',
      market: Market.us,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));
    await _fillAndPreview(tester);
    expect(find.text('SIMULATED'), findsOneWidget);
    expect(find.byKey(const Key('sim_preview_warning')), findsOneWidget);
  });

  testWidgets('Insufficient simulated cash error is surfaced verbatim',
      (tester) async {
    const msg = 'Insufficient simulated cash for this order.';
    final sim = _FakeSim(placeStatus: 400, placeDetail: msg);
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: 'AAPL',
      market: Market.us,
      side: OrderSide.buy,
      repository: _repo(sim),
    )));
    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.text(msg), findsOneWidget);
  });
}
