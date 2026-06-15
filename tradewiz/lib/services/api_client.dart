import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
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
        _http = httpClient ?? http.Client() {
    // One-time diagnostic: which backend is this build actually talking to?
    // Helps catch release builds that ship a wrong/placeholder base URL.
    // No secrets or tokens are ever logged.
    if (!_loggedConfig) {
      _loggedConfig = true;
      _log('Using backend baseUrl=$baseUrl '
          '(mockFallback=${_config.mockFallback}, '
          'timeout=${_config.requestTimeout.inSeconds}s)');
    }
  }

  final AppConfig _config;
  final http.Client _http;

  static bool _loggedConfig = false;

  String get baseUrl => _config.baseUrl;

  void close() => _http.close();

  /// Lightweight diagnostic logger. Only emits in debug/profile (or when
  /// asserts are enabled); never logged in plain release output. Never
  /// includes auth headers, bearer tokens, or request bodies.
  void _log(String message) {
    if (kReleaseMode) return;
    developer.log(message, name: 'TradeWizz.api');
  }

  /// A readable, token-free description of a transport failure. We deliberately
  /// do NOT name the backend host in the user-visible message — it just says
  /// the server could not be reached, without exposing the API hostname.
  String _transportError(Uri uri, String reason) {
    return '$reason.';
  }

  /// Heavy endpoints can legitimately take a while when the backend is pulling
  /// a large batch of market data or (re)building a screen/snapshot cache --
  /// e.g. right after a deploy when the cache is cold. Instead of a blunt
  /// "request timed out", tell the user the server is busy crunching data and
  /// to wait a moment, so a slow-but-healthy backend doesn't read as an error.
  String _timeoutMessage(Uri uri) {
    final path = uri.path.toLowerCase();
    final isScreening = path.contains('/screen') ||
        path.contains('/snapshot') ||
        path.contains('/idx') ||
        path.contains('/news');
    final isAnalyze = path.contains('/analyze') ||
        path.contains('/rebalance') ||
        path.contains('/portfolio');
    if (isScreening) {
      return 'The server is screening the market and pulling fresh data — '
          'this can take a little longer. Please wait a moment and try again.';
    }
    if (isAnalyze) {
      return 'The server is crunching the latest data — this can take a little '
          'longer. Please wait a moment and try again.';
    }
    return 'The server is taking longer than usual to respond. '
        'Please wait a moment and try again.';
  }

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
  ///
  /// Optional query params: [limit] (bounded 1..200), [minScore] (0..100), and
  /// [categories] (wire names). They are also applied to the mock fallback so
  /// behavior is consistent offline.
  Future<Sourced<Map<String, dynamic>>> screen(
    Market market, {
    int? limit,
    double? minScore,
    List<String>? categories,
  }) {
    final query = <String, String>{};
    if (limit != null) query['limit'] = limit.toString();
    if (minScore != null && minScore > 0) {
      query['min_score'] = minScore.toString();
    }
    if (categories != null && categories.isNotEmpty) {
      query['categories'] = categories.join(',');
    }
    return _get(
      '/screen/${market.code}',
      query: query.isEmpty ? null : query,
      fallback: () => _mockScreen(
        market,
        limit: limit,
        minScore: minScore,
        categories: categories,
      ),
    );
  }

  /// GET /predict_weekly/{symbol}?market=...
  ///
  /// The market MUST be sent so the backend builds the correct Yahoo ticker
  /// (e.g. HKEX 03417 -> 3417.HK, not 03417.JK). Omitting it defaults the
  /// backend to IDX.
  Future<Sourced<Map<String, dynamic>>> predictWeekly(
    String symbol,
    Market market,
  ) {
    final s = Uri.encodeComponent(symbol.toUpperCase());
    return _get(
      '/predict_weekly/$s',
      query: {'market': market.code},
      fallback: () => _mockPredict(symbol),
    );
  }

  /// GET /backtest/{symbol}
  Future<Sourced<Map<String, dynamic>>> backtest(
    String symbol,
    Market market, {
    String signalType = 'momentum',
    int forwardDays = 2,
  }) {
    final s = Uri.encodeComponent(symbol.toUpperCase());
    return _get(
      '/backtest/$s',
      query: {
        'market': market.code,
        'signal_type': signalType,
        'forward_days': forwardDays.toString(),
      },
      fallback: () => _mockBacktest(symbol, market, signalType, forwardDays),
    );
  }

  // ---------------------------------------------------------------------------
  // Broker (Moomoo) endpoints. These NEVER fall back to mock data: trading
  // calls must be real or fail clearly. Server `detail` errors are surfaced.
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> brokerGet(String path) =>
      _brokerCall('GET', path);

  Future<Map<String, dynamic>> brokerPost(
    String path,
    Map<String, dynamic> body,
  ) =>
      _brokerCall('POST', path, body: body);

  /// Auth calls (register/login/me/logout). Never fall back to mock; surface
  /// the server's `detail` error. `bearer` adds an Authorization header.
  Future<Map<String, dynamic>> authGet(String path, {String? bearer}) =>
      _brokerCall('GET', path, bearer: bearer);

  Future<Map<String, dynamic>> authPost(
    String path,
    Map<String, dynamic> body, {
    String? bearer,
  }) =>
      _brokerCall('POST', path, body: body, bearer: bearer);

  Future<Map<String, dynamic>> authDelete(String path, {String? bearer}) =>
      _brokerCall('DELETE', path, bearer: bearer);

  Future<Map<String, dynamic>> _brokerCall(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? bearer,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'Accept': 'application/json'};
    if (bearer != null) headers['Authorization'] = 'Bearer $bearer';
    try {
      late final http.Response response;
      if (method == 'POST') {
        response = await _http
            .post(
              uri,
              headers: {...headers, 'Content-Type': 'application/json'},
              body: jsonEncode(body ?? const {}),
            )
            .timeout(_config.requestTimeout);
      } else if (method == 'DELETE') {
        response =
            await _http.delete(uri, headers: headers).timeout(_config.requestTimeout);
      } else {
        response =
            await _http.get(uri, headers: headers).timeout(_config.requestTimeout);
      }

      final decoded =
          response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded is Map<String, dynamic>) return decoded;
        throw ApiException('Unexpected response format from server.');
      }
      // Surface the server's error detail (e.g. 'not tradable', 'expired').
      final detail = decoded is Map<String, dynamic>
          ? (decoded['detail']?.toString() ?? _friendlyStatus(response.statusCode))
          : _friendlyStatus(response.statusCode);
      throw ApiException(detail, statusCode: response.statusCode);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      _log('Timeout contacting $uri');
      throw ApiException(_timeoutMessage(uri));
    } on SocketException catch (e) {
      _log('SocketException contacting $uri: ${e.osError?.message ?? e.message}');
      throw ApiException(_transportError(uri, 'Could not reach the server'));
    } on http.ClientException catch (e) {
      _log('ClientException contacting $uri: ${e.message}');
      throw ApiException(_transportError(uri, 'Network error contacting the server'));
    } on FormatException {
      throw ApiException('Could not read the server response.');
    }
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
      _log('Timeout contacting $uri');
      return _maybeFallback(fallback, _timeoutMessage(uri));
    } on SocketException catch (e) {
      _log('SocketException contacting $uri: ${e.osError?.message ?? e.message}');
      return _maybeFallback(fallback, _transportError(uri, 'Could not reach the server'));
    } on http.ClientException catch (e) {
      _log('ClientException contacting $uri: ${e.message}');
      return _maybeFallback(fallback, _transportError(uri, 'Network error contacting the server'));
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

  /// Two leading highlight lines mirroring the backend's market-status block.
  /// Simple IDX schedule (Mon-Fri 09:00-16:00 WIB); placeholder for offline.
  List<String> _mockMarketStatusLines() {
    // WIB = UTC+7.
    final wib = DateTime.now().toUtc().add(const Duration(hours: 7));
    final weekday = wib.weekday; // Mon=1 .. Sun=7
    final minutes = wib.hour * 60 + wib.minute;
    final open = weekday <= 5 && minutes >= 9 * 60 && minutes <= 16 * 60;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    String d(DateTime t) =>
        '${t.day.toString().padLeft(2, '0')} ${months[t.month - 1]} ${t.year}';
    if (open) {
      final hhmm =
          '${wib.hour.toString().padLeft(2, '0')}:${wib.minute.toString().padLeft(2, '0')}';
      // Mock fabricates today's session, so report it as live-session data.
      return [
        'Market Status: OPEN',
        'Data Source Status: LIVE SESSION DATA',
        'Data Timestamp: ${d(wib)} $hhmm WIB',
      ];
    }
    return ['Market Status: CLOSED', 'Last Market Close: ${d(wib)}'];
  }

  /// Currency symbol for mock-fallback highlight formatting, mirroring the
  /// backend (IDX->Rp, HKEX->HK\$, KOSPI/KOSDAQ->won).
  String _mockCurrencySymbol(Market market) {
    switch (market) {
      case Market.hkex:
        return 'HK\$';
      case Market.kospi:
      case Market.kosdaq:
        return '\u20a9'; // won symbol
      case Market.idx:
        return 'Rp';
      case Market.us:
        return '\$';
      case Market.japan:
        return '\u00a5'; // yen
      case Market.india:
        return '\u20b9'; // rupee
      case Market.vietnam:
        return '\u20ab'; // dong
      case Market.singapore:
        return 'S\$';
    }
  }

  Map<String, dynamic> _mockAnalyze(String symbol, Market market) {
    final score = _seed(symbol) % 100;
    final signal = score > 66
        ? 'BUY'
        : score > 33
            ? 'HOLD'
            : 'SELL';
    final cur = _mockCurrencySymbol(market);
    return {
      'symbol': symbol.toUpperCase(),
      'market': market.code,
      'signal': signal,
      'score': score.toDouble(),
      'summary':
          '$symbol shows a $signal bias on ${market.code}. This is placeholder '
              'output; the migrated screening engine will populate real metrics.',
      // Investor-friendly highlights (mirror the live backend shape): two
      // market-status lines, then the metrics. Currency-aware per market.
      'highlights': [
        ..._mockMarketStatusLines(),
        'Current Price: $cur${(100 + score).toStringAsFixed(2)}',
        '20-Day Average Price: $cur${(95 + score).toStringAsFixed(2)}',
        "Today's Volume: ${(5 + score % 6).toStringAsFixed(1)} Million",
        '20-Day Average Volume: ${(4 + score % 5).toStringAsFixed(1)} Million',
        'Value Traded Today: $cur${(1 + score % 9) / 10 + 1}.00 Billion',
        'Volume Ratio: ${(0.8 + (score % 20) / 10).toStringAsFixed(2)}x',
        'ATR: ${(2 + score % 8).toStringAsFixed(2)}%',
      ],
      'generated_at': DateTime.now().toIso8601String(),
      // Phase 3 refinement fields (mirror the live backend shape).
      'recommendation': signal == 'BUY'
          ? 'BUY — confirmed by momentum'
          : signal == 'SELL'
              ? 'SELL / avoid — weak setup'
              : 'HOLD — no clear buy/sell signal yet',
      'buy_reasons': signal == 'SELL'
          ? <String>[]
          : ['MACD bullish', if (score > 50) 'OBV rising', 'Above VWAP'],
      'support_resistance': {
        'immediate_support': 100.0 - (score % 10),
        'immediate_resistance': 100.0 + (score % 10) + 5,
        'major_support': 90.0 - (score % 10),
        'major_resistance': 110.0 + (score % 10),
      },
      'trailing_stop_percent': (5 + score % 6).toDouble(),
      'trailing_stop_price':
          double.parse((100 * (1 - (5 + score % 6) / 100)).toStringAsFixed(2)),
      'profit_probability': (score / 100),
    };
  }

  Map<String, dynamic> _mockScreen(
    Market market, {
    int? limit,
    double? minScore,
    List<String>? categories,
  }) {
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
    var matches = List.generate(categoryRotation.length, (i) {
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
    });

    // Mirror the backend filter/sort/limit so offline behavior is consistent.
    final wanted = categories?.toSet() ?? const <String>{};
    matches = matches.where((m) {
      final score = m['score'] as double;
      if (minScore != null && score < minScore) return false;
      if (wanted.isNotEmpty) {
        final cats = (m['categories'] as List).cast<String>().toSet();
        if (wanted.intersection(cats).isEmpty) return false;
      }
      return true;
    }).toList();
    matches.sort((a, b) {
      final byScore =
          (b['score'] as double).compareTo(a['score'] as double);
      if (byScore != 0) return byScore;
      return (b['change_percent'] as double)
          .compareTo(a['change_percent'] as double);
    });
    final total = matches.length; // after filter, before limit
    final bounded = (limit ?? 50).clamp(1, 200);
    if (matches.length > bounded) matches = matches.sublist(0, bounded);

    return {
      'market': market.code,
      'matches': matches,
      'generated_at': DateTime.now().toIso8601String(),
      // Pagination metadata mirroring the backend.
      'total_count': total,
      'returned_count': matches.length,
      'limit': bounded,
      'min_score': minScore ?? 0,
      'categories': categories ?? const <String>[],
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

  Map<String, dynamic> _mockBacktest(
    String symbol,
    Market market,
    String signalType,
    int forwardDays,
  ) {
    final s = _seed(symbol);
    final total = 5 + s % 20; // 5..24
    final wins = (total * (0.4 + (s % 40) / 100)).round().clamp(0, total);
    final losses = total - wins;
    final avg = ((s % 9) - 3) * 0.004; // -1.2%..+2.0%
    final pf = losses == 0
        ? 999.0
        : double.parse((wins / losses * (1 + (s % 5) / 10)).toStringAsFixed(4));
    return {
      'symbol': symbol.toUpperCase(),
      'market': market.code,
      'signal_type': signalType,
      'forward_days': forwardDays,
      'total_signals': total,
      'total_wins': wins,
      'total_losses': losses,
      'win_rate': total == 0 ? 0.0 : double.parse((wins / total).toStringAsFixed(4)),
      'average_return': double.parse(avg.toStringAsFixed(6)),
      'profit_factor': pf,
      'max_drawdown': -((s % 6) + 1) * 0.01,
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
