import 'dart:async';

import '../models/market.dart';

/// Thrown when an API call fails.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Low-level client for the TradeWiz backend (the migrated Telegram bot API).
///
/// Endpoints are defined here as placeholders. Networking is stubbed for now:
/// each method returns mocked JSON so the UI can be built and tested before the
/// real backend is wired in. Swap [_mockGet] for a real HTTP call later.
class ApiClient {
  ApiClient({this.baseUrl = 'https://api.tradewiz.app/v1'});

  /// Base URL of the backend. Override per-environment.
  final String baseUrl;

  /// GET /analyze/{symbol}
  Future<Map<String, dynamic>> analyze(String symbol, Market market) {
    return _mockGet('/analyze/$symbol', () => _mockAnalyze(symbol, market));
  }

  /// GET /screen/{market}
  Future<Map<String, dynamic>> screen(Market market) {
    return _mockGet('/screen/${market.code}', () => _mockScreen(market));
  }

  /// GET /predict_weekly/{symbol}
  Future<Map<String, dynamic>> predictWeekly(String symbol) {
    return _mockGet('/predict_weekly/$symbol', () => _mockPredict(symbol));
  }

  // ---------------------------------------------------------------------------
  // Transport (stubbed). Replace this with a real http/dio implementation.
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _mockGet(
    String path,
    Map<String, dynamic> Function() build,
  ) async {
    // Simulate network latency.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return build();
  }

  // ---------------------------------------------------------------------------
  // Mock payload builders (placeholder data shaped like the real API).
  // ---------------------------------------------------------------------------

  Map<String, dynamic> _mockAnalyze(String symbol, Market market) {
    final score = _seed(symbol) % 100;
    final signal = score > 66
        ? 'BUY'
        : score > 33
            ? 'HOLD'
            : 'SELL';
    return {
      'symbol': symbol.toUpperCase(),
      'market': market.code,
      'signal': signal,
      'score': score.toDouble(),
      'summary':
          '$symbol shows a $signal bias on ${market.code}. This is placeholder '
              'output; the migrated screening engine will populate real metrics.',
      'highlights': [
        'Momentum: ${score > 50 ? 'positive' : 'weak'}',
        'Relative strength vs ${market.code}: ${score > 60 ? 'leader' : 'lagger'}',
        'Volume trend: ${score % 2 == 0 ? 'rising' : 'flat'}',
      ],
      'generated_at': DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _mockScreen(Market market) {
    return {
      'market': market.code,
      'matches': List.generate(5, (i) {
        final score = (90 - i * 7).toDouble();
        return {
          'symbol': '${market.code}$i',
          'name': 'Sample ${market.code} Co. $i',
          'score': score,
          'signal': score > 66 ? 'BUY' : 'HOLD',
          'price': 1000 + i * 137.0,
          'change_percent': (i.isEven ? 1 : -1) * (i + 1) * 0.8,
        };
      }),
      'generated_at': DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _mockPredict(String symbol) {
    final s = _seed(symbol);
    final dir = s % 3 == 0
        ? 'UP'
        : s % 3 == 1
            ? 'DOWN'
            : 'FLAT';
    return {
      'symbol': symbol.toUpperCase(),
      'direction': dir,
      'expected_change_percent': ((s % 7) - 3) * 0.9,
      'confidence': 0.5 + (s % 50) / 100,
      'rationale':
          'Placeholder weekly forecast for $symbol. Real prediction will come '
              'from the migrated model.',
    };
  }

  int _seed(String symbol) {
    var h = 0;
    for (final c in symbol.toUpperCase().codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}
