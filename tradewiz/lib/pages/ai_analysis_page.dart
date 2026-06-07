import 'package:flutter/material.dart';

import '../models/analysis_result.dart';
import '../models/broker.dart';
import '../models/market.dart';
import '../models/watchlist_item.dart';
import '../repositories/stock_repository.dart';
import 'order_ticket_page.dart';
import '../services/api_client.dart';
import '../services/data_source.dart';
import '../services/repository_scope.dart';
import '../services/watchlist_scope.dart';
import '../theme.dart';
import '../widgets/connection_pill.dart';

/// Full-screen analysis route with a back button. Used when navigating from a
/// screener match: prefills the symbol/market and auto-runs the analysis.
class AnalysisDetailPage extends StatelessWidget {
  const AnalysisDetailPage({
    super.key,
    required this.symbol,
    required this.market,
    this.repository,
  });

  final String symbol;
  final Market market;
  final StockRepository? repository;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '$symbol · ${market.code}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: AiAnalysisPage(
          market: market,
          initialSymbol: symbol,
          autoRun: true,
          repository: repository ?? RepositoryScope.of(context),
        ),
      ),
    );
  }
}

/// AI Analysis: enter a symbol + market, fetch a (placeholder) analysis result.
class AiAnalysisPage extends StatefulWidget {
  const AiAnalysisPage({
    super.key,
    this.market,
    this.repository,
    this.initialSymbol,
    this.autoRun = false,
  });

  /// Optional market preselected from the app shell.
  final Market? market;
  final StockRepository? repository;

  /// Symbol to prefill (e.g. when opened from a screener match).
  final String? initialSymbol;

  /// When true, runs the analysis automatically on first build.
  final bool autoRun;

  @override
  State<AiAnalysisPage> createState() => _AiAnalysisPageState();
}

class _AiAnalysisPageState extends State<AiAnalysisPage> {
  late final StockRepository _repo = widget.repository ?? StockRepository();
  final _formKey = GlobalKey<FormState>();
  final _symbolController = TextEditingController();

  late Market _market = widget.market ?? Market.idx;
  bool _loading = false;
  String? _error;
  AnalysisResult? _result;
  WeeklyPrediction? _prediction;
  BacktestResult? _backtest;
  DataSource? _source;

  @override
  void initState() {
    super.initState();
    if (widget.initialSymbol != null) {
      _symbolController.text = widget.initialSymbol!.trim().toUpperCase();
    }
    if (widget.autoRun && (widget.initialSymbol?.trim().isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _submit());
    }
  }

  @override
  void dispose() {
    _symbolController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final symbol = _symbolController.text.trim().toUpperCase();

    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _prediction = null;
      _backtest = null;
      _source = null;
    });

    try {
      final analysis = await _repo.analyze(symbol, _market);
      final prediction = await _repo.predictWeekly(symbol);
      final backtest = await _repo.backtest(symbol, _market);
      if (!mounted) return;
      setState(() {
        _result = analysis.data;
        _prediction = prediction.data;
        _backtest = backtest.data;
        // Worst-of the sources (fallback outranks live) so the pill is honest.
        _source = _worst(
          _worst(analysis.source, prediction.source),
          backtest.source,
        );
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _source = e.statusCode == null ? DataSource.offline : DataSource.error;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load analysis. $e';
        _source = DataSource.error;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Returns the less-trustworthy of two sources for an honest combined pill.
  DataSource _worst(DataSource a, DataSource b) {
    int rank(DataSource s) => switch (s) {
          DataSource.live => 0,
          DataSource.fallback => 1,
          DataSource.offline => 2,
          DataSource.error => 3,
        };
    return rank(a) >= rank(b) ? a : b;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _buildForm(),
        const SizedBox(height: 20),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_error != null) _ErrorCard(message: _error!),
        if (_result != null && !_loading) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                const Text(
                  'Result',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                ),
                const Spacer(),
                ConnectionPill(source: _source),
              ],
            ),
          ),
          ConnectionBanner(
            source: _source,
            onRetry: _submit,
            retrying: _loading,
          ),
          _ResultCard(result: _result!),
          if (_result!.recommendation != null ||
              _result!.profitProbability != null ||
              _result!.buyReasons.isNotEmpty) ...[
            const SizedBox(height: 16),
            _RecommendationCard(result: _result!),
          ],
          if (_result!.supportResistance != null) ...[
            const SizedBox(height: 16),
            _SupportResistanceCard(sr: _result!.supportResistance!),
          ],
          if (_result!.trailingStopPercent != null) ...[
            const SizedBox(height: 16),
            _TrailingStopCard(result: _result!),
          ],
          const SizedBox(height: 12),
          _SaveToWatchlistButton(result: _result!),
          const SizedBox(height: 12),
          _BuySellButtons(
            symbol: _result!.symbol,
            market: _result!.market,
            repository: _repo,
          ),
          if (_prediction != null) ...[
            const SizedBox(height: 16),
            _PredictionCard(prediction: _prediction!),
          ],
          if (_backtest != null) ...[
            const SizedBox(height: 16),
            _BacktestCard(backtest: _backtest!),
          ],
        ],
        if (_result == null && !_loading && _error == null) const _EmptyHint(),
      ],
    );
  }

  Widget _buildForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Analyze a Stock',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _symbolController,
                textCapitalization: TextCapitalization.characters,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Stock symbol',
                  hintText: 'e.g. BBCA, 0700, 005930',
                  prefixIcon: Icon(Icons.tag),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'Enter a stock symbol';
                  if (t.length > 12) return 'Symbol looks too long';
                  return null;
                },
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Market>(
                initialValue: _market,
                decoration: const InputDecoration(
                  labelText: 'Market',
                  prefixIcon: Icon(Icons.public),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final m in Market.values)
                    DropdownMenuItem(
                      value: m,
                      child: Text('${m.flag}  ${m.code}'),
                    ),
                ],
                onChanged: (m) => setState(() => _market = m ?? _market),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _loading ? null : _submit,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Analyze'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Adds the analyzed symbol to the shared watchlist (reflects saved state).
/// Buy / Sell buttons. Only shown for markets tradable via Moomoo (HKEX);
/// for others, shows a clear 'not tradable' note. Opens the manual order
/// ticket -> preview -> confirm flow (never auto-submits).
class _BuySellButtons extends StatelessWidget {
  const _BuySellButtons({
    required this.symbol,
    required this.market,
    required this.repository,
  });

  final String symbol;
  final Market market;
  final StockRepository repository;

  // Single source of truth on the Market enum (mirrors backend symbol_map).
  bool get _tradable => market.tradableViaMoomoo;

  void _open(BuildContext context, OrderSide side) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderTicketPage(
          symbol: symbol,
          market: market,
          side: side,
          repository: repository,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_tradable) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const Icon(Icons.block, size: 18, color: Colors.grey),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${market.code} is not tradable via Moomoo.',
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
          ]),
        ),
      );
    }
    return Row(children: [
      Expanded(
        child: FilledButton.icon(
          key: const Key('buy_button'),
          onPressed: () => _open(context, OrderSide.buy),
          icon: const Icon(Icons.trending_up),
          label: const Text('Buy'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.up,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: FilledButton.icon(
          key: const Key('sell_button'),
          onPressed: () => _open(context, OrderSide.sell),
          icon: const Icon(Icons.trending_down),
          label: const Text('Sell'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.down,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    ]);
  }
}

class _SaveToWatchlistButton extends StatelessWidget {
  const _SaveToWatchlistButton({required this.result});
  final AnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final store = WatchlistScope.of(context); // subscribes to changes
    final saved = store.contains(result.symbol, result.market);

    return SizedBox(
      width: double.infinity,
      child: saved
          ? OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.check),
              label: const Text('Saved to Watchlist'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            )
          : FilledButton.tonalIcon(
              icon: const Icon(Icons.star_outline),
              label: const Text('Save to Watchlist'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () {
                WatchlistScope.read(context).add(
                  WatchlistItem(
                    symbol: result.symbol,
                    name: result.symbol,
                    market: result.market,
                  ),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        '${result.symbol} added to ${result.market.code} watchlist'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
  final AnalysisResult result;

  Color get _signalColor => switch (result.signal) {
        'BUY' => AppColors.up,
        'SELL' => AppColors.down,
        _ => Colors.orange,
      };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.symbol,
                        style: const TextStyle(
                            fontWeight: FontWeight.w800, fontSize: 20),
                      ),
                      Text(
                        '${result.market.flag} ${result.market.code}',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: _signalColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    result.signal,
                    style: TextStyle(
                      color: _signalColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  'Score ${result.score.toStringAsFixed(0)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: (result.score / 100).clamp(0, 1),
                      minHeight: 8,
                      color: _signalColor,
                      backgroundColor: _signalColor.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(result.summary),
            const SizedBox(height: 16),
            ...result.highlights.map(
              (h) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 18, color: AppColors.seed),
                    const SizedBox(width: 8),
                    Expanded(child: Text(h)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Placeholder result · generated ${_time(result.generatedAt)}',
              style: const TextStyle(color: Colors.grey, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// Recommendation + profit probability + buy reasons (Phase 3).
class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.result});
  final AnalysisResult result;

  @override
  Widget build(BuildContext context) {
    final prob = result.profitProbability;
    final color = switch (result.signal) {
      'BUY' => AppColors.up,
      'SELL' => AppColors.down,
      _ => Colors.orange,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Recommendation',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 8),
            if (result.recommendation != null)
              Text(
                result.recommendation!,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 15),
              ),
            if (prob != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const Icon(Icons.percent, size: 16, color: AppColors.seed),
                  const SizedBox(width: 6),
                  Text('Profit probability  '
                      '${(prob * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: prob.clamp(0, 1),
                  minHeight: 8,
                  color: AppColors.seed,
                  backgroundColor: AppColors.seed.withValues(alpha: 0.12),
                ),
              ),
            ],
            if (result.buyReasons.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Text('Reasons',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in result.buyReasons)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: AppColors.up.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check, size: 13,
                              color: AppColors.up),
                          const SizedBox(width: 4),
                          Text(r,
                              style: const TextStyle(
                                  color: AppColors.up,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12)),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Support/resistance levels (Phase 3).
class _SupportResistanceCard extends StatelessWidget {
  const _SupportResistanceCard({required this.sr});
  final SupportResistance sr;

  String _fmt(double? v) => v == null ? '—' : v.toStringAsFixed(v >= 100 ? 0 : 2);

  @override
  Widget build(BuildContext context) {
    Widget level(String label, double? v, Color c, IconData icon) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 13, color: c),
                const SizedBox(width: 4),
                Text(label,
                    style: const TextStyle(color: Colors.grey, fontSize: 11)),
              ]),
              const SizedBox(height: 2),
              Text(_fmt(v),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Support / Resistance',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 12),
            Row(children: [
              level('Imm. support', sr.immediateSupport, AppColors.up,
                  Icons.south),
              level('Imm. resistance', sr.immediateResistance, AppColors.down,
                  Icons.north),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              level('Major support', sr.majorSupport, AppColors.up,
                  Icons.keyboard_double_arrow_down),
              level('Major resistance', sr.majorResistance, AppColors.down,
                  Icons.keyboard_double_arrow_up),
            ]),
          ],
        ),
      ),
    );
  }
}

/// ADX-banded trailing stop (Phase 3).
class _TrailingStopCard extends StatelessWidget {
  const _TrailingStopCard({required this.result});
  final AnalysisResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.orange.withValues(alpha: 0.12),
              child: const Icon(Icons.vertical_align_bottom,
                  color: Colors.orange),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Suggested trailing stop',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '${result.trailingStopPercent!.toStringAsFixed(0)}%'
                    '${result.trailingStopPrice != null ? '  ·  at '
                        '${result.trailingStopPrice!.toStringAsFixed(result.trailingStopPrice! >= 100 ? 0 : 2)}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Backtest stats (Phase 5).
class _BacktestCard extends StatelessWidget {
  const _BacktestCard({required this.backtest});
  final BacktestResult backtest;

  @override
  Widget build(BuildContext context) {
    final b = backtest;
    Widget stat(String label, String value, {Color? color}) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 2),
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color ?? const Color(0xFF1A1C1E))),
          ],
        );
    final avgPct = b.averageReturn * 100;
    final ddPct = b.maxDrawdown * 100;
    final pf = b.profitFactor >= 999 ? '∞' : b.profitFactor.toStringAsFixed(2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.history, size: 18, color: AppColors.seed),
              const SizedBox(width: 8),
              const Text('Backtest',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const Spacer(),
              Text('${b.signalType} · ${b.forwardDays}d',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
            const SizedBox(height: 14),
            if (!b.hasSignals)
              const Text('No historical signals for this rule.',
                  style: TextStyle(color: Colors.grey))
            else ...[
              Row(children: [
                Expanded(
                    child: stat('Win rate',
                        '${(b.winRate * 100).toStringAsFixed(0)}%',
                        color: b.winRate >= 0.5
                            ? AppColors.up
                            : AppColors.down)),
                Expanded(
                    child: stat('Avg return',
                        '${avgPct >= 0 ? '+' : ''}${avgPct.toStringAsFixed(2)}%',
                        color: avgPct >= 0 ? AppColors.up : AppColors.down)),
                Expanded(child: stat('Profit factor', pf)),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                    child: stat('Max drawdown',
                        '${ddPct.toStringAsFixed(2)}%',
                        color: AppColors.down)),
                Expanded(child: stat('Total signals', '${b.totalSignals}')),
                Expanded(
                    child: stat('W / L',
                        '${b.totalWins} / ${b.totalLosses}')),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

class _PredictionCard extends StatelessWidget {
  const _PredictionCard({required this.prediction});
  final WeeklyPrediction prediction;

  @override
  Widget build(BuildContext context) {
    final up = prediction.direction == 'UP';
    final down = prediction.direction == 'DOWN';
    final color = up
        ? AppColors.up
        : down
            ? AppColors.down
            : Colors.orange;
    final icon = up
        ? Icons.trending_up
        : down
            ? Icons.trending_down
            : Icons.trending_flat;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Weekly forecast: ${prediction.direction}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${prediction.expectedChangePercent >= 0 ? '+' : ''}'
                    '${prediction.expectedChangePercent.toStringAsFixed(1)}% · '
                    '${(prediction.confidence * 100).toStringAsFixed(0)}% confidence',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.down.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.down),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 40),
      child: Column(
        children: const [
          Icon(Icons.auto_awesome_outlined, size: 48, color: Colors.grey),
          SizedBox(height: 12),
          Text(
            'Enter a symbol and market to get a placeholder analysis.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
