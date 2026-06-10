import 'package:flutter/material.dart';

import '../models/phase2.dart';
import '../repositories/stock_repository.dart';
import '../services/api_client.dart';
import '../services/auth_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';
import '../theme_tradewizz.dart';
import 'ds/ds.dart';

/// AI Portfolio Manager card — a rule-based advisory over the simulated
/// portfolio (risk level, scores, and plain-language recommendations).
/// Research/simulation only.
class PortfolioManagerCard extends StatefulWidget {
  const PortfolioManagerCard({super.key, this.repository});

  final StockRepository? repository;

  @override
  State<PortfolioManagerCard> createState() => _PortfolioManagerCardState();
}

class _PortfolioManagerCardState extends State<PortfolioManagerCard> {
  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);

  String? get _token {
    final notifier =
        context.getInheritedWidgetOfExactType<AuthScope>()?.notifier;
    return notifier?.token;
  }

  bool _loading = true;
  bool _error = false;
  PortfolioManagerReport? _report;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loading && _report == null) _load();
  }

  Future<void> _load() async {
    final token = _token;
    if (token == null) {
      setState(() {
        _loading = false;
        _report = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final r = await _repo.portfolioManager(token);
      if (!mounted) return;
      setState(() {
        _report = r;
        _loading = false;
        _error = false;
      });
    } on ApiException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  Color _riskColor(String level) => {
        'LOW': AppColors.up,
        'HIGH': AppColors.down,
      }[level] ??
      Colors.orange;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('portfolio_manager_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.smart_toy_outlined,
                color: AppColors.seed, size: 20),
            const SizedBox(width: 8),
            const Text('AI Portfolio Manager',
                key: Key('portfolio_manager_title'),
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    color: TWColors.textPrimary)),
          ],
        ),
        const SizedBox(height: 8),
        if (_loading && _report == null)
          const Card(
            key: Key('portfolio_manager_loading'),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_token == null)
          const TWFloatingCard(
            child: Text('Sign in to get AI portfolio guidance.',
                style: TextStyle(color: TWColors.textTertiary)),
          )
        else if (_error || _report == null)
          const TWFloatingCard(
            key: Key('portfolio_manager_unavailable'),
            child: Text('Portfolio manager unavailable.',
                style: TextStyle(color: TWColors.down)),
          )
        else
          _ReportCard(report: _report!, riskColor: _riskColor),
      ],
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.riskColor});
  final PortfolioManagerReport report;
  final Color Function(String) riskColor;

  @override
  Widget build(BuildContext context) {
    return TWFloatingCard(
      key: const Key('portfolio_manager_report'),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Risk Level',
                    style: TextStyle(
                        color: TWColors.textTertiary, fontSize: 12)),
                const Spacer(),
                Container(
                  key: const Key('portfolio_manager_risk'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: riskColor(report.riskLevel).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(report.riskLevel,
                      style: TextStyle(
                          color: riskColor(report.riskLevel),
                          fontWeight: FontWeight.w800,
                          fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _ScoreCell(
                    label: 'Portfolio', value: report.portfolioScore),
                _ScoreCell(
                    label: 'Diversif.',
                    value: report.diversificationScore),
                _ScoreCell(
                    label: 'Concentr.',
                    value: report.concentrationScore),
              ],
            ),
            const Divider(height: 24),
            const Text('Recommendations',
                style: TextStyle(
                    color: TWColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (report.recommendations.isEmpty)
              const Text('No recommendations right now.',
                  style: TextStyle(
                      color: TWColors.textTertiary, fontSize: 13))
            else
              for (final rec in report.recommendations)
                _RecTile(rec: rec),
          ],
      ),
    );
  }
}

class _ScoreCell extends StatelessWidget {
  const _ScoreCell({required this.label, required this.value});
  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value.toStringAsFixed(0),
              style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: TWColors.textPrimary)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: TWColors.textTertiary, fontSize: 11)),
        ],
      ),
    );
  }
}

class _RecTile extends StatelessWidget {
  const _RecTile({required this.rec});
  final PmRecommendation rec;

  Color get _color => {
        'critical': AppColors.down,
        'warning': Colors.orange,
      }[rec.severity] ??
      AppColors.seed;

  IconData get _icon => {
        'concentration': Icons.pie_chart_outline,
        'weak_position': Icons.trending_down,
        'strong_position': Icons.trending_up,
        'cash_allocation': Icons.account_balance_wallet_outlined,
        'diversification': Icons.scatter_plot_outlined,
      }[rec.kind] ??
      Icons.info_outline;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('pm_rec_${rec.kind}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_icon, size: 18, color: _color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rec.title.isNotEmpty)
                  Text(rec.title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: TWColors.textPrimary)),
                Text(rec.message,
                    style: const TextStyle(
                        fontSize: 12, color: TWColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
