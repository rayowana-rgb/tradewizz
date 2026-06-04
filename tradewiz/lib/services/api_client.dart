import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/market.dart';
import 'data_source.dart';

/// Thrown when an API call fails in a way the UI should surface.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Low-level client for the TradeWiz backend (the migrated Telegram bot API).
///
/// Performs real HTTP GETs against [AppConfig.baseUrl]. If the backend is
/// unreachable (and [AppConfig.mockFallback] is on), it falls back to mocked
/// JSON so the app stays usable offline / before the backend is deployed.
class ApiClient {
  ApiClient({AppConfig? config, http.Client? httpClient})
      : _config = config ?? AppConfig.fromEnvironment(),
        _http = httpClient ?? http.Client();

  final AppConfig _config;
  final http.Client _http;

  String get baseUrl => _config.baseUrl;

  void close() => _http.close();

  /// GET /analyze/{symbol}
  Future<Sourced<Map<String, dynamic>>> analyze(String symbol, Market market) {
    final s = Uri.encodeComponent(symbol.toUpperCase());
    return _get(
      '/analyze/$s',
      query: {'market': market.code},
      fallback: () => _mockAnalyze(symbol, market),
    );
  }

  /// GET /screen/{market}
  Future<Sourced<Map<String, dynamic>>> screen(Market market) {
    return _get(
      '/screen/${market.code}',
      fallback: () => _mockScreen(market),
    );
  }

  /// GET /predict_weekly/{symbol}
  Future<Sourced<Map<String, dynamic>>> predictWeekly(String symbol) {
    final s = Uri.encodeComponent(symbol.toUpperCase());
    return _get(
      '/predict_weekly/$s',
      fallback: () => _mockPredict(symbol),
    );
  }

  // ---------------------------------------------------------------------------
  // HTTP transport with timeout, friendly errors, and mock fallback.
  // ---------------------------------------------------------------------------

  Future<Sourced<Map<String, dynamic>>> _get(
    String path, {
    Map<String, String>? query,
    required Map<String, dynamic> Function() fallback,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(
      queryParameters: query == null || query.isEmpty ? null : query,
    );

    try {
      final response = await _http
          .get(uri, headers: const {'Accept': 'application/json'})
          .timeout(_config.requestTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          return Sourced(decoded, DataSource.live);
        }
        throw ApiException('Unexpected response format from server.');
      }

      // Non-2xx: these are real server answers, so surface them (no fallback).
      throw ApiException(
        _friendlyStatus(response.statusCode),
        statusCode: response.statusCode,
      );
    } on ApiException {
      rethrow;
    } on TimeoutException {
      return _maybeFallback(fallback, 'The request timed out.');
    } on SocketException {
      return _maybeFallback(fallback, 'Could not reach the server.');
    } on http.ClientException {
      return _maybeFallback(fallback, 'Network error contacting the server.');
    } on FormatException {
      throw ApiException('Could not read the server response.');
    }
  }

  Sourced<Map<String, dynamic>> _maybeFallback(
    Map<String, dynamic> Function() fallback,
    String message,
  ) {
    if (_config.mockFallback) {
      return Sourced(fallback(), DataSource.fallback);
    }
    throw ApiException(message);
  }

  String _friendlyStatus(int code) {
    return switch (code) {
      400 => 'Invalid request.',
      401 || 403 => 'Not authorized.',
      404 => 'Not found.',
      429 => 'Too many requests — please slow down.',
      >= 500 => 'The server is having trouble. Try again shortly.',
      _ => 'Request failed (HTTP $code).',
    };
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
    // Cycle through the full category taxonomy so the UI/filters have coverage.
    const categoryRotation = <List<String>>[
      ['bullish', 'ara_hunter'],
      ['bearish', 'short_candidate'],
      ['scalping', 'frequently_traded'],
      ['accumulation', 'pullback'],
      ['accumulation_silent'],
      ['turnaround_multibagger', 'bullish'],
      ['pullback', 'accumulation'],
      ['frequently_traded'],
      ['ara_hunter', 'scalping'],
      ['short_candidate'],
    ];
    return {
      'market': market.code,
      'matches': List.generate(categoryRotation.length, (i) {
        final score = (95 - i * 6).toDouble();
        final cats = categoryRotation[i];
        final bearish =
            cats.contains('bearish') || cats.contains('short_candidate');
        return {
          'symbol': '${market.code}${(i + 1).toString().padLeft(2, '0')}',
          'name': 'Sample ${market.code} Co. ${i + 1}',
          'score': score,
          'signal': bearish
              ? 'SELL'
              : score > 66
                  ? 'BUY'
                  : 'HOLD',
          'price': 1000 + i * 137.0,
          'change_percent': (bearish ? -1 : 1) * (i % 5 + 1) * 0.8,
          'categories': cats,
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
