import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/data_source.dart';

AppConfig _config({bool mockFallback = true}) => AppConfig(
      baseUrl: 'https://test.tradewiz.app/v1',
      requestTimeout: const Duration(seconds: 5),
      mockFallback: mockFallback,
    );

void main() {
  test('analyze() parses a real 200 JSON response', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/v1/analyze/BBCA');
      expect(req.url.queryParameters['market'], 'IDX');
      return http.Response(
        jsonEncode({
          'symbol': 'BBCA',
          'market': 'IDX',
          'signal': 'BUY',
          'score': 88,
          'summary': 'Strong.',
          'highlights': ['a', 'b'],
          'generated_at': '2026-06-04T00:00:00Z',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final client = ApiClient(config: _config(), httpClient: mock);
    final res = await client.analyze('bbca', Market.idx);
    expect(res.source, DataSource.live);
    expect(res.data['signal'], 'BUY');
    expect(res.data['score'], 88);
  });

  test('screen() hits /screen/{market}', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/v1/screen/HKEX');
      return http.Response(
        jsonEncode({'market': 'HKEX', 'matches': []}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final client = ApiClient(config: _config(), httpClient: mock);
    final res = await client.screen(Market.hkex);
    expect(res.source, DataSource.live);
    expect(res.data['market'], 'HKEX');
  });

  test('falls back to mock data when the server is unreachable', () async {
    final mock = MockClient((req) async {
      throw http.ClientException('offline');
    });
    final client = ApiClient(config: _config(mockFallback: true), httpClient: mock);

    final res = await client.analyze('TLKM', Market.idx);
    // Mock fallback shape still present, tagged as fallback.
    expect(res.source, DataSource.fallback);
    expect(res.data['symbol'], 'TLKM');
    expect(res.data['signal'], isNotNull);
  });

  test('no fallback => throws friendly ApiException when offline', () async {
    final mock = MockClient((req) async {
      throw http.ClientException('offline');
    });
    final client =
        ApiClient(config: _config(mockFallback: false), httpClient: mock);

    expect(
      () => client.screen(Market.idx),
      throwsA(isA<ApiException>()),
    );
  });

  test('non-2xx surfaces a friendly error (no silent fallback)', () async {
    final mock = MockClient((req) async => http.Response('nope', 500));
    final client = ApiClient(config: _config(), httpClient: mock);

    await expectLater(
      () => client.predictWeekly('ABCD'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', contains('server')),
      ),
    );
  });
}
