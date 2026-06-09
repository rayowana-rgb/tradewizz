import 'package:flutter/material.dart';

import '../models/market.dart';
import '../models/phase2.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// The "AI Morning Brief" dashboard section — a rule-based, once-per-session
/// market summary (top opportunity, top multibagger, strongest sector, market
/// regime). Research only; no broker data.
class AiMorningBriefSection extends StatefulWidget {
  const AiMorningBriefSection({
    super.key,
    required this.market,
    this.repository,
  });

  final Market market;
  final StockRepository? repository;

  @override
  State<AiMorningBriefSection> createState() => _AiMorningBriefSectionState();
}

class _AiMorningBriefSectionState extends State<AiMorningBriefSection> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = false;
  bool _unavailable = false;
  MorningBrief? _brief;
  Market? _loadedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedFor != widget.market) {
      _loadedFor = widget.market;
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant AiMorningBriefSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.market != widget.market) {
      _loadedFor = widget.market;
      _load();
    }
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _brief = null;
        _unavailable = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final b = await _repo.morningBrief(token, widget.market);
      if (!mounted) return;
      setState(() {
        _brief = b;
        _unavailable = false;
        _loading = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _brief = null;
        _unavailable = true;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('morning_brief_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.wb_sunny_outlined,
                color: AppColors.seed, size: 20),
            const SizedBox(width: 8),
            const Text('AI Morning Brief',
                key: Key('morning_brief_title'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const Spacer(),
            _PreviewTag(),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading && _brief == null)
          const Card(
            key: Key('morning_brief_loading'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_token == null)
          const Card(
            key: Key('morning_brief_signed_out'),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Sign in to get your once-a-day AI Morning Brief.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          )
        else if (_unavailable || _brief == null)
          Card(
            key: const Key('morning_brief_unavailable'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: const [
                  Icon(Icons.error_outline, color: AppColors.down, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text('Morning Brief unavailable',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.down)),
                  ),
                ],
              ),
            ),
          )
        else
          _BriefCard(brief: _brief!),
      ],
    );
  }
}

class _BriefCard extends StatelessWidget {
  const _BriefCard({required this.brief});
  final MorningBrief brief;

  @override
  Widget build(BuildContext context) {
    final regimeColor = {
      'BULL': AppColors.up,
      'BEAR': AppColors.down,
    }[brief.marketRegime] ??
        Colors.grey;
    return Card(
      key: const Key('morning_brief_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${brief.market.flag} ${brief.market.code} MARKET',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 14)),
                const Spacer(),
                _RegimeChip(regime: brief.marketRegime, color: regimeColor),
              ],
            ),
            const SizedBox(height: 8),
            Text(brief.headline,
                key: const Key('morning_brief_headline'),
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
            const Divider(height: 24),
            if (brief.topOpportunity != null)
              _BriefRow(
                keyName: 'morning_brief_top_opportunity',
                label: 'Top Opportunity',
                pick: brief.topOpportunity!,
              ),
            if (brief.topMultibagger != null) ...[
              const SizedBox(height: 12),
              _BriefRow(
                keyName: 'morning_brief_top_multibagger',
                label: 'Top Multibagger Candidate',
                pick: brief.topMultibagger!,
              ),
            ],
            const Divider(height: 24),
            Row(
              children: [
                const Icon(Icons.category_outlined,
                    size: 16, color: Colors.grey),
                const SizedBox(width: 6),
                const Text('Strongest Sector',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                const Spacer(),
                Text(brief.strongestSector,
                    key: const Key('morning_brief_strongest_sector'),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
            if (brief.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final note in brief.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ',
                          style: TextStyle(color: Colors.grey)),
                      Expanded(
                        child: Text(note,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54)),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BriefRow extends StatelessWidget {
  const _BriefRow({
    required this.keyName,
    required this.label,
    required this.pick,
  });
  final String keyName;
  final String label;
  final BriefPick pick;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: Key(keyName),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(pick.symbol,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.seed.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('Score ${pick.score.toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: AppColors.seed,
                      fontWeight: FontWeight.w700,
                      fontSize: 11)),
            ),
          ],
        ),
        if (pick.reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(pick.reason,
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ],
    );
  }
}

class _RegimeChip extends StatelessWidget {
  const _RegimeChip({required this.regime, required this.color});
  final String regime;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = {
      'BULL': 'Bullish',
      'BEAR': 'Defensive',
      'NEUTRAL': 'Mixed',
    }[regime] ??
        regime;
    return Container(
      key: const Key('morning_brief_regime'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontWeight: FontWeight.w700, fontSize: 11)),
    );
  }
}

class _PreviewTag extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text('PREVIEW',
          style: TextStyle(
              color: Color(0xFF8A6D00),
              fontWeight: FontWeight.w800,
              fontSize: 10)),
    );
  }
}
