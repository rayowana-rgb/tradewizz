@Tags(['live'])
library;

/// End-to-end smoke test against a REAL running backend.
///
/// This is NOT part of the default unit-test run (it needs a live server and
/// network access). Start the backend first, then run it explicitly:
///
///   # terminal 1
///   cd backend && source .venv/bin/activate
///   uvicorn app.main:app --port 8000
///
///   # terminal 2
///   cd tradewiz
///   flutter test --tags live \
///     --dart-define=TRADEWIZ_API_BASE_URL=http://localhost:8000/v1 \
///     --dart-define=RUN_LIVE=true
///
/// It verifies the app receives LIVE data (not the mock fallback) for all
/// three endpoints.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:tradewiz/config/app_config.dart';
import 'package:tradewiz/models/market.dart';
import 'package:tradewiz/repositories/stock_repository.dart';
import 'package:tradewiz/services/api_client.dart';
import 'package:tradewiz/services/data_source.dart';

/// Gate so the suite is inert during a normal `flutter test` run. Enable with
/// `--dart-define=RUN_LIVE=true` (the `live` tag does the selection).
const _runLive = bool.fromEnvironment('RUN_LIVE', defaultValue: false);

void main() {
  if (!_runLive) {
    test('live backend smoke (skipped: pass --dart-define=RUN_LIVE=true)', () {},
        skip: 'Set --dart-define=RUN_LIVE=true and run with --tags live');
    return;
  }

  // Resolve base URL from --dart-define (default matches AppConfig).
  final config = AppConfig.fromEnvironment();

  late ApiClient client;
  late StockRepository repo;

  setUp(() {
    // Real HTTP client + real config; fallback OFF so a failure can't be
    // silently masked as "live" — we want a hard error if the server is down.
    final liveConfig = AppConfig(
      baseUrl: config.baseUrl,
      requestTimeout: const Duration(seconds: 8),
      mockFallback: false,
    );
    client = ApiClient(config: liveConfig, httpClient: http.Client());
    repo = StockRepository(client: client);
  });

  tearDown(() => client.close());

  test('analyze() returns LIVE data from the backend', () async {
    final res = await repo.analyze('BBCA', Market.idx);
    expect(res.source, DataSource.live,
        reason: 'Expected live backend data, got ${res.source}. '
            'Is the server running at ${config.baseUrl}?');
    expect(res.data.symbol, 'BBCA');
    expect(res.data.market, Market.idx);
    expect(res.data.signal, anyOf('BUY', 'HOLD', 'SELL'));
  });

  test('screen() returns LIVE data with categories', () async {
    final res = await repo.screen(Market.kosdaq);
    expect(res.source, DataSource.live);
    expect(res.data.market, Market.kosdaq);
    expect(res.data.matches, isNotEmpty);
    expect(res.data.matches.first.categories, isNotEmpty);
  });

  test('predictWeekly() returns LIVE data', () async {
    final res = await repo.predictWeekly('0700');
    expect(res.source, DataSource.live);
    expect(res.data.symbol, '0700');
    expect(res.data.direction, anyOf('UP', 'DOWN', 'FLAT'));
  });
}
