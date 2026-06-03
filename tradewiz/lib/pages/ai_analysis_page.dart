import 'package:flutter/material.dart';

import '../models/analysis_result.dart';
import '../models/market.dart';
import '../repositories/stock_repository.dart';
import '../theme.dart';

/// AI Analysis: enter a symbol + market, fetch a (placeholder) analysis result.
class AiAnalysisPage extends StatefulWidget {
  const AiAnalysisPage({super.key, this.market, this.repository});

  /// Optional market preselected from the app shell.
  final Market? market;
  final StockRepository? repository;

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
    });

    try {
      final results = await Future.wait([
        _repo.analyze(symbol, _market),
        _repo.predictWeekly(symbol),
      ]);
      if (!mounted) return;
      setState(() {
        _result = results[0] as AnalysisResult;
        _prediction = results[1] as WeeklyPrediction;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not load analysis. $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
          _ResultCard(result: _result!),
          if (_prediction != null) ...[
            const SizedBox(height: 16),
            _PredictionCard(prediction: _prediction!),
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
