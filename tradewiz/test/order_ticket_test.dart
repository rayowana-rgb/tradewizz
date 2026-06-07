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

/// Fake IBKR order backend. Records calls + bearer so tests can assert that
/// preview does not place, that place carries the confirmation token, and that
/// auth flows through. Order endpoints can be made to reject with a specific
/// backend `detail` to verify the UI surfaces it verbatim.
class _FakeIbkr {
  _FakeIbkr({this.placeStatus = 200, this.placeDetail});

  final List<String> calls = [];
  final List<String?> bearers = [];
  String? lastPlaceToken;

  /// HTTP status to return from /place (e.g. 409 read-only, 400 funds).
  final int placeStatus;

  /// `detail` to return from /place when [placeStatus] != 200.
  final String? placeDetail;

  http.Response handle(http.Request req) {
    calls.add('${req.method} ${req.url.path}');
    bearers.add(req.headers['Authorization']);
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.url.path.endsWith('/brokers/ibkr/order/preview')) {
      return http.Response(
        jsonEncode({
          'symbol': body['symbol'],
          'market': body['market'],
          'moomoo_code': 'SEHK:700',
          'side': body['side'],
          'quantity': body['quantity'],
          'order_type': body['order_type'],
          'price': body['price'],
          'estimated_value':
              (body['quantity'] as num) * ((body['price'] as num?) ?? 0),
          'currency': 'HKD',
          'trading_env': 'PAPER',
          'is_real': false,
          'confirmation_token': 'TOKEN-123',
          'expires_in_seconds': 120,
          'warnings': <String>[],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (req.url.path.endsWith('/brokers/ibkr/order/place')) {
      lastPlaceToken = body['confirmation_token'] as String?;
      if (placeStatus != 200) {
        return http.Response(
          jsonEncode({'detail': placeDetail}),
          placeStatus,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'order_id': 'IBKR-1',
          'symbol': body['symbol'],
          'market': body['market'],
          'side': body['side'],
          'quantity': body['quantity'],
          'order_type': body['order_type'],
          'status': 'SUBMITTED',
          'trading_env': 'PAPER',
          'is_real': false,
          'message': 'Order submitted.',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.Response('not found', 404);
  }
}

StockRepository _repo(_FakeIbkr broker) => StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async => broker.handle(req)),
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

Future<void> _fillAndPreview(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('qty_field')), '100');
  await tester.enterText(find.byKey(const Key('price_field')), '400');
  await tester.tap(find.text('Preview order'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Preview does NOT place an order (IBKR endpoint, authed)',
      (tester) async {
    final broker = _FakeIbkr();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: '0700',
      market: Market.hkex,
      side: OrderSide.buy,
      repository: _repo(broker),
    )));

    await _fillAndPreview(tester);

    expect(find.text('Order Preview'), findsOneWidget);
    expect(broker.calls, ['POST /v1/brokers/ibkr/order/preview']);
    expect(broker.calls.any((c) => c.contains('/place')), isFalse);
    // Authenticated: bearer token sent on the order call.
    expect(broker.bearers.first, 'Bearer JWT-TEST');
  });

  testWidgets('Confirm places the order WITH the confirmation token',
      (tester) async {
    final broker = _FakeIbkr();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: '0700',
      market: Market.hkex,
      side: OrderSide.buy,
      repository: _repo(broker),
    )));

    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.text('Order SUBMITTED'), findsOneWidget);
    expect(broker.calls, [
      'POST /v1/brokers/ibkr/order/preview',
      'POST /v1/brokers/ibkr/order/place',
    ]);
    expect(broker.lastPlaceToken, 'TOKEN-123');
    expect(broker.bearers.last, 'Bearer JWT-TEST');
  });

  testWidgets('PAPER env chip is shown on the preview', (tester) async {
    final broker = _FakeIbkr();
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: '0700',
      market: Market.hkex,
      side: OrderSide.buy,
      repository: _repo(broker),
    )));
    await _fillAndPreview(tester);
    expect(find.text('PAPER'), findsOneWidget);
  });

  testWidgets('Read-Only mode error is surfaced verbatim (not "Order failed")',
      (tester) async {
    const msg = 'IB Gateway is currently running in Read-Only API mode. '
        'Disable Read-Only to place orders.';
    final broker = _FakeIbkr(placeStatus: 409, placeDetail: msg);
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: '0700',
      market: Market.hkex,
      side: OrderSide.buy,
      repository: _repo(broker),
    )));
    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.text(msg), findsOneWidget);
    expect(find.text('Order failed'), findsNothing);
  });

  testWidgets('Insufficient buying power error is surfaced', (tester) async {
    const msg = 'Insufficient buying power to place this order.';
    final broker = _FakeIbkr(placeStatus: 400, placeDetail: msg);
    await tester.pumpWidget(_wrap(OrderTicketPage(
      symbol: '0700',
      market: Market.hkex,
      side: OrderSide.buy,
      repository: _repo(broker),
    )));
    await _fillAndPreview(tester);
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.text(msg), findsOneWidget);
  });
}
