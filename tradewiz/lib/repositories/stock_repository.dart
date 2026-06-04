import '../models/analysis_result.dart';
import '../models/market.dart';
import '../models/screener_result.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';

/// High-level access point for stock data.
///
/// The UI talks to the repository; the repository talks to [ApiClient]. Results
/// are wrapped in [Sourced] so the UI can show whether data is live or fallback.
/// Hard failures throw [ApiException]; callers map that to an error/offline
/// status in the UI.
class StockRepository {
  StockRepository({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// Full analysis for a single symbol. Backs `/analyze/{symbol}`.
  Future<Sourced<AnalysisResult>> analyze(String symbol, Market market) async {
    final res = await _client.analyze(symbol, market);
    return Sourced(AnalysisResult.fromJson(res.data), res.source);
  }

  /// Screener results for a market. Backs `/screen/{market}`.
  ///
  /// Optional [limit] (top-N), [minScore], and [categories] (wire names) are
  /// forwarded to the API as query params when set.
  Future<Sourced<ScreenerResult>> screen(
    Market market, {
    int? limit,
    double? minScore,
    List<String>? categories,
  }) async {
    final res = await _client.screen(
      market,
      limit: limit,
      minScore: minScore,
      categories: categories,
    );
    return Sourced(ScreenerResult.fromJson(res.data), res.source);
  }

  /// Weekly prediction for a symbol. Backs `/predict_weekly/{symbol}`.
  Future<Sourced<WeeklyPrediction>> predictWeekly(String symbol) async {
    final res = await _client.predictWeekly(symbol);
    return Sourced(WeeklyPrediction.fromJson(res.data), res.source);
  }

  /// Backtest a buy-signal rule for a symbol. Backs `/backtest/{symbol}`.
  Future<Sourced<BacktestResult>> backtest(
    String symbol,
    Market market, {
    String signalType = 'momentum',
    int forwardDays = 2,
  }) async {
    final res = await _client.backtest(
      symbol,
      market,
      signalType: signalType,
      forwardDays: forwardDays,
    );
    return Sourced(BacktestResult.fromJson(res.data), res.source);
  }
}
