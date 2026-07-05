import 'package:flutter/material.dart';

import '../models/momentum.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/moomoo_secret_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';

/// Strategy Comparison (owner-only, read-only).
///
/// Splits the ONE live account into three sleeves — momentum, passive, cash —
/// and compares them against the owner's 50 / 30 / 20 target. Shows current
/// weight vs target (drift) plus, once enough real observations have been
/// recorded, each sleeve's total return and max drawdown (the resilience
/// measure). Return / drawdown stay as "collecting data" until the backend has
/// at least two observations — nothing is fabricated.
class StrategyComparisonPage extends StatefulWidget {
  const StrategyComparisonPage({
    super.key,
    required this.repository,
    required this.secretStore,
  });

  final StockRepository repository;
  final MoomooSecretStore secretStore;

  @override
  State<StrategyComparisonPage> createState() => _StrategyComparisonPageState();
}

class _StrategyComparisonPageState extends State<StrategyComparisonPage> {
  PortfolioSleeves? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final token = AuthScope.read(context).token;
    final secret = widget.secretStore.secret;
    if (token == null || secret == null || secret.isEmpty) {
      setState(() {
        _error = 'LIVE trading unavailable (missing credentials).';
        _loading = false;
      });
      return;
    }
    try {
      final d = await widget.repository.momentumSleeves(
        token: token,
        secret: secret,
      );
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load strategy comparison. $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TWColors.bgBase,
      appBar: AppBar(
        backgroundColor: TWColors.bgBase,
        elevation: 0,
        title: const Text('Strategy Comparison', style: TWType.body),
      ),
      body: TWScaffoldBackground(
        child: SafeArea(
          top: false,
          child: RefreshIndicator(
            color: TWColors.accent,
            backgroundColor: TWColors.surfaceCard,
            onRefresh: _refresh,
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const TWBusyIndicator(
        title: 'Loading sleeves…',
        subtitle: 'Splitting the live account into momentum / passive / cash.',
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(TWSpace.lg),
        children: [
          TWEmptyState(
            title: 'Comparison unavailable',
            body: _error,
            ctaLabel: 'Retry',
            onCta: _refresh,
          ),
        ],
      );
    }
    final d = _data;
    if (d == null) {
      return const SizedBox.shrink();
    }

    final momentum = d.byName('momentum');
    final passive = d.byName('passive');
    final cash = d.byName('cash');

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          TWSpace.lg, TWSpace.md, TWSpace.lg, TWSpace.xxxl),
      children: [
        _totalCard(d),
        const SizedBox(height: TWSpace.lg),
        Text('Allocation vs target',
            style: TWType.label.copyWith(color: TWColors.textSecondary)),
        const SizedBox(height: TWSpace.sm),
        if (momentum != null) _allocRow(momentum, TWColors.accent),
        if (passive != null) _allocRow(passive, TWColors.up),
        if (cash != null) _allocRow(cash, TWColors.warn),
        const SizedBox(height: TWSpace.xl),
        Text('Performance (momentum vs passive)',
            style: TWType.label.copyWith(color: TWColors.textSecondary)),
        const SizedBox(height: TWSpace.sm),
        if (!d.metricsReady) _collectingNote(),
        if (d.metricsReady) ...[
          if (momentum != null) _perfRow(momentum, TWColors.accent),
          if (passive != null) _perfRow(passive, TWColors.up),
        ],
        const SizedBox(height: TWSpace.lg),
        Text(
          'Target 50% momentum · 30% passive · 20% cash buffer. Return and max '
          'drawdown are computed only from real recorded observations — they '
          'grow as you use the app.',
          style: TWType.caption.copyWith(color: TWColors.textTertiary),
        ),
      ],
    );
  }

  Widget _totalCard(PortfolioSleeves d) {
    return TWGlassCard(
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Total account value',
              style: TWType.caption.copyWith(color: TWColors.textTertiary)),
          const SizedBox(height: TWSpace.xs),
          Text('\$${d.totalValue.toStringAsFixed(2)}', style: TWType.title3),
          const SizedBox(height: TWSpace.xs),
          Text('${d.sleeves.length} sleeves · momentum / passive / cash',
              style: TWType.caption.copyWith(color: TWColors.textTertiary)),
        ],
      ),
    );
  }

  Widget _allocRow(PortfolioSleeve s, Color color) {
    final curPct = (s.weight * 100);
    final tgtPct = (s.targetWeight * 100);
    final driftPct = (s.drift * 100);
    // Bar fill clamped to [0,1]; negative cash shows an empty bar.
    final fill = s.weight.clamp(0.0, 1.0).toDouble();
    final tgtMarker = s.targetWeight.clamp(0.0, 1.0).toDouble();
    final overTarget = s.drift > 0.005;
    final underTarget = s.drift < -0.005;
    final driftColor =
        overTarget || underTarget ? TWColors.warn : TWColors.up;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: TWSpace.md),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: TWColors.hairlineTop, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(_label(s.name), style: TWType.label),
              const Spacer(),
              Text('${curPct.toStringAsFixed(1)}%',
                  style: TWType.tabular(TWType.label).copyWith(color: color)),
              const SizedBox(width: TWSpace.sm),
              Text('/ ${tgtPct.toStringAsFixed(0)}% target',
                  style: TWType.caption.copyWith(color: TWColors.textTertiary)),
            ],
          ),
          const SizedBox(height: TWSpace.sm),
          _allocBar(fill, tgtMarker, color),
          const SizedBox(height: TWSpace.xs),
          Row(
            children: [
              Text(
                s.name == 'cash'
                    ? '\$${s.marketValue.toStringAsFixed(0)} free'
                    : '${s.positions} name(s) · \$${s.marketValue.toStringAsFixed(0)}',
                style: TWType.caption.copyWith(color: TWColors.textTertiary),
              ),
              const Spacer(),
              Text(
                '${driftPct >= 0 ? '+' : ''}${driftPct.toStringAsFixed(1)}% vs target',
                style: TWType.caption.copyWith(color: driftColor),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _allocBar(double fill, double target, Color color) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: 10,
        child: Stack(
          children: [
            // Track.
            Container(
              decoration: BoxDecoration(
                color: TWColors.bgRaised,
                borderRadius: BorderRadius.circular(TWRadius.sm),
              ),
            ),
            // Fill.
            FractionallySizedBox(
              widthFactor: fill,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(TWRadius.sm),
                ),
              ),
            ),
            // Target marker.
            Positioned(
              left: (w * target).clamp(0.0, w - 2),
              top: -2,
              bottom: -2,
              child: Container(width: 2, color: TWColors.textSecondary),
            ),
          ],
        ),
      );
    });
  }

  Widget _perfRow(PortfolioSleeve s, Color color) {
    final r = s.returnPct;
    final dd = s.maxDrawdown;
    final rUp = (r ?? 0) >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: TWSpace.md),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: TWColors.hairlineTop, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(
                  color: color, shape: BoxShape.circle)),
          const SizedBox(width: TWSpace.sm),
          Text(_label(s.name), style: TWType.label),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                r == null
                    ? '—'
                    : '${rUp ? '+' : ''}${(r * 100).toStringAsFixed(2)}% return',
                style: TWType.tabular(TWType.label).copyWith(
                    color: r == null
                        ? TWColors.textTertiary
                        : (rUp ? TWColors.up : TWColors.down)),
              ),
              const SizedBox(height: TWSpace.xs),
              Text(
                dd == null
                    ? 'drawdown —'
                    : 'worst drawdown ${(dd * 100).toStringAsFixed(2)}%',
                style: TWType.caption.copyWith(color: TWColors.textTertiary),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _collectingNote() => TWGlassCard(
        child: Row(
          children: [
            const Icon(Icons.hourglass_empty,
                size: 16, color: TWColors.textTertiary),
            const SizedBox(width: TWSpace.sm),
            Expanded(
              child: Text(
                'Collecting data. Return and drawdown appear once at least two '
                'observations have been recorded — open this screen over the '
                'coming days to build the comparison.',
                style:
                    TWType.caption.copyWith(color: TWColors.textTertiary),
              ),
            ),
          ],
        ),
      );

  String _label(String name) {
    switch (name) {
      case 'momentum':
        return 'Momentum';
      case 'passive':
        return 'Passive';
      case 'cash':
        return 'Cash buffer';
      default:
        return name;
    }
  }
}
