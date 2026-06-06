import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/broker.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/pages/order_ticket_page.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';

/// Fake broker backend: records the calls it receives so tests can assert that
/// preview does not place and place includes the confirmation token.
class _FakeBroker {
  final List<String> calls = [];
  String? lastPlaceToken;

  http.Response handle(http.Request req) {
    calls.add('${req.method} ${req.url.path}');
    final body = req.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(req.body) as Map<String, dynamic>;

    if (req.url.path.endsWith('/broker/order/preview')) {
      return http.Response(
        jsonEncode({
          'symbol': body['symbol'],
          'market': body['market'],
          'moomoo_code': 'HK.00700',
          'side': body['side'],
          'quantity': body['quantity'],
          'order_type': body['order_type'],
          'price': body['price'],
          'estimated_value': (body['quantity'] as num) *
              ((body['price'] as num?) ?? 0),
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
    if (req.url.path.endsWith('/broker/order/place')) {
      lastPlaceToken = body['confirmation_token'] as String?;
      return http.Response(
        jsonEncode({
          'order_id': 'MOCK-1',
          'symbol': body['symbol'],
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

StockRepository _repo(_FakeBroker broker) => StockRepository(
      client: ApiClient(
        config: const AppConfig(baseUrl: 'https://test.tradewiz.app/v1'),
        httpClient: MockClient((req) async => broker.handle(req)),
      ),
    );

void main() {
  testWidgets('Preview does NOT place an order', (tester) async {
    final broker = _FakeBroker();
    await tester.pumpWidget(MaterialApp(
      home: OrderTicketPage(
        symbol: '0700',
        market: Market.hkex,
        side: OrderSide.buy,
        repository: _repo(broker),
      ),
    ));

    await tester.enterText(find.byKey(const Key('qty_field')), '100');
    await tester.enterText(find.byKey(const Key('price_field')), '400');
    await tester.tap(find.text('Preview order'));
    await tester.pumpAndSettle();

    // Preview screen shown; ONLY the preview call was made (no place).
    expect(find.text('Order Preview'), findsOneWidget);
    expect(broker.calls, ['POST /v1/broker/order/preview']);
    expect(broker.calls.any((c) => c.contains('/place')), isFalse);
  });

  testWidgets('Confirm places the order WITH the confirmation token',
      (tester) async {
    final broker = _FakeBroker();
    await tester.pumpWidget(MaterialApp(
      home: OrderTicketPage(
        symbol: '0700',
        market: Market.hkex,
        side: OrderSide.buy,
        repository: _repo(broker),
      ),
    ));

    await tester.enterText(find.byKey(const Key('qty_field')), '100');
    await tester.enterText(find.byKey(const Key('price_field')), '400');
    await tester.tap(find.text('Preview order'));
    await tester.pumpAndSettle();

    // Explicit confirmation step.
    await tester.tap(find.byKey(const Key('confirm_place_button')));
    await tester.pumpAndSettle();

    expect(find.text('Order SUBMITTED'), findsOneWidget);
    // Place happened after preview, and carried the token from the preview.
    expect(broker.calls,
        ['POST /v1/broker/order/preview', 'POST /v1/broker/order/place']);
    expect(broker.lastPlaceToken, 'TOKEN-123');
  });

  testWidgets('PAPER env chip is shown on the preview', (tester) async {
    final broker = _FakeBroker();
    await tester.pumpWidget(MaterialApp(
      home: OrderTicketPage(
        symbol: '0700',
        market: Market.hkex,
        side: OrderSide.buy,
        repository: _repo(broker),
      ),
    ));
    await tester.enterText(find.byKey(const Key('qty_field')), '100');
    await tester.enterText(find.byKey(const Key('price_field')), '400');
    await tester.tap(find.text('Preview order'));
    await tester.pumpAndSettle();
    expect(find.text('PAPER'), findsOneWidget);
  });
}
