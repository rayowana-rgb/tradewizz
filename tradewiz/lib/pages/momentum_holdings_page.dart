import 'package:flutter/material.dart';

import '../models/momentum.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/moomoo_secret_store.dart';
import '../theme_tradewizz.dart';
import '../widgets/ds/ds.dart';

/// Momentum Holdings (owner-only, read-only).
///
/// Shows the LIVE positions momentum actually bought — the local ledger
/// (`data/momentum_holdings.json`) intersected with the live Moomoo positions —
/// with per-name unrealized P/L and a flag for whether each name is still in the
/// current top-N (i.e. a HOLD at the next monthly rebalance). Positions from the
/// owner's OTHER strategies are never shown, because only ledger symbols are
/// considered. Names the ledger tracks but that are no longer held live (sold
/// manually elsewhere) are surfaced separately as "no longer held".
class MomentumHoldingsPage extends StatefulWidget {
  const MomentumHoldingsPage({
    super.key,
    required this.repository,
    required this.secretStore,
    this.topN = 10,
  });

  final StockRepository repository;
  final MoomooSecretStore secretStore;
  final int topN;

  @override
  State<MomentumHoldingsPage> createState() => _MomentumHoldingsPageState();
}

class _MomentumHoldingsPageState extends State<MomentumHoldingsPage> {
  MomentumHoldings? _data;
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
      final d = await widget.repository.momentumHoldings(
        topN: widget.topN,
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
        _error = 'Could not load momentum holdings. $e';
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
        title: const Text('Momentum Holdings', style: TWType.body),
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
        title: 'Loading holdings…',
        subtitle: 'Reading the momentum ledger and live positions.',
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.all(TWSpace.lg),
        children: [
          TWEmptyState(
            title: 'Holdings unavailable',
            body: _error,
            ctaLabel: 'Retry',
            onCta: _refresh,
          ),
        ],
      );
    }
    final d = _data;
    if (d == null || d.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(TWSpace.lg),
        children: [
          const TWEmptyState(
            title: 'No momentum holdings yet',
            body: 'Positions you buy from Momentum Research will appear here, '
                'tracked separately from your other strategies.',
          ),
          if (d != null && d.staleSymbols.isNotEmpty) ...[
            const SizedBox(height: TWSpace.lg),
            _staleNote(d.staleSymbols),
          ],
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          TWSpace.lg, TWSpace.md, TWSpace.lg, TWSpace.xxxl),
      children: [
        _totalsCard(d),
        const SizedBox(height: TWSpace.lg),
        Text('${d.holdings.length} position(s) · momentum only',
            style: TWType.label.copyWith(color: TWColors.textSecondary)),
        const SizedBox(height: TWSpace.sm),
        ...d.holdings.map(_holdingRow),
        const SizedBox(height: TWSpace.md),
        Text(
          'Names in the top ${d.topN} are kept at the next monthly rebalance; '
          'the rest would be sold.',
          style: TWType.caption.copyWith(color: TWColors.textTertiary),
        ),
        if (d.staleSymbols.isNotEmpty) ...[
          const SizedBox(height: TWSpace.lg),
          _staleNote(d.staleSymbols),
        ],
      ],
    );
  }

  Widget _totalsCard(MomentumHoldings d) {
    final plUp = d.totalUnrealizedPl >= 0;
    final plColor = plUp ? TWColors.up : TWColors.down;
    return TWGlassCard(
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Momentum portfolio value',
              style: TWType.caption.copyWith(color: TWColors.textTertiary)),
          const SizedBox(height: TWSpace.xs),
          Text('\$${d.totalMarketValue.toStringAsFixed(2)}',
              style: TWType.title3),
          const SizedBox(height: TWSpace.sm),
          Row(
            children: [
              Icon(plUp ? Icons.trending_up : Icons.trending_down,
                  size: 16, color: plColor),
              const SizedBox(width: TWSpace.xs),
              Text(
                '${plUp ? '+' : ''}\$${d.totalUnrealizedPl.toStringAsFixed(2)} '
                'unrealized',
                style: TWType.label.copyWith(color: plColor),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _holdingRow(MomentumHolding h) {
    final plUp = h.unrealizedPl >= 0;
    final plColor = plUp ? TWColors.up : TWColors.down;
    final pct = (h.unrealizedPlRatio * 100).toStringAsFixed(2);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: TWSpace.md),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: TWColors.hairlineTop, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(h.symbol, style: TWType.body),
                    const SizedBox(width: TWSpace.sm),
                    if (h.inTopN)
                      _tag('Top ${h.rank ?? ''}'.trim(), TWColors.accent)
                    else
                      _tag('Drops out', TWColors.warn),
                  ],
                ),
                const SizedBox(height: TWSpace.xs),
                Text(
                  '${h.qty.toStringAsFixed(4)} sh · avg '
                  '\$${h.costPrice.toStringAsFixed(2)} · '
                  'last \$${h.lastPrice.toStringAsFixed(2)}',
                  style: TWType.caption.copyWith(color: TWColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: TWSpace.md),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$${h.marketValue.toStringAsFixed(2)}',
                  style: TWType.tabular(TWType.label)),
              const SizedBox(height: TWSpace.xs),
              Text(
                '${plUp ? '+' : ''}\$${h.unrealizedPl.toStringAsFixed(2)} '
                '(${plUp ? '+' : ''}$pct%)',
                style: TWType.tabular(TWType.caption).copyWith(color: plColor),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tag(String label, Color color) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: TWSpace.sm, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: TWRadius.rChip,
        ),
        child: Text(label,
            style: TWType.overline.copyWith(color: color)),
      );

  Widget _staleNote(List<String> symbols) => TWGlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.info_outline,
                    size: 16, color: TWColors.textTertiary),
                const SizedBox(width: TWSpace.xs),
                Text('No longer held',
                    style: TWType.label
                        .copyWith(color: TWColors.textSecondary)),
              ],
            ),
            const SizedBox(height: TWSpace.xs),
            Text(
              '${symbols.join(', ')} — tracked by momentum but not in your '
              'live account any more (sold elsewhere). They are ignored at '
              'rebalance.',
              style: TWType.caption.copyWith(color: TWColors.textTertiary),
            ),
          ],
        ),
      );
}
