import '../models/analysis_result.dart';
import '../models/market.dart';
import '../models/screener_result.dart';
import '../services/api_client.dart';

/// High-level access point for stock data.
///
/// The UI talks to the repository; the repository talks to [ApiClient]. This
/// keeps networking/serialization out of widgets and makes it easy to swap the
/// data source (real API, cache, mocks) without touching the UI.
class StockRepository {
  StockRepository({ApiClient? client}) : _client = client ?? ApiClient();

  final ApiClient _client;

  /// Full analysis for a single symbol. Backs `/analyze/{symbol}`.
  Future<AnalysisResult> analyze(String symbol, Market market) async {
    final json = await _client.analyze(symbol, market);
    return AnalysisResult.fromJson(json);
  }

  /// Screener results for a market. Backs `/screen/{market}`.
  Future<ScreenerResult> screen(Market market) async {
    final json = await _client.screen(market);
    return ScreenerResult.fromJson(json);
  }

  /// Weekly prediction for a symbol. Backs `/predict_weekly/{symbol}`.
  Future<WeeklyPrediction> predictWeekly(String symbol) async {
    final json = await _client.predictWeekly(symbol);
    return WeeklyPrediction.fromJson(json);
  }
}
