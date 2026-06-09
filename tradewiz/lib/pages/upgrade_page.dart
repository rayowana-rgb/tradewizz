import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/entitlements_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// Phase 7 — the premium / upgrade screen.
///
/// Shows the current plan, a FREE/PRO/ELITE comparison table, and Upgrade
/// buttons. Pure research/AI/simulation product: there is NO broker or
/// real-money feature here. Billing is a placeholder (the backend activates the
/// tier without taking payment).
class UpgradePage extends StatefulWidget {
  const UpgradePage({super.key, this.repository, this.highlightFeature});

  final StockRepository? repository;

  /// Optional feature key to highlight (e.g. when opened from a locked card).
  final String? highlightFeature;

  @override
  State<UpgradePage> createState() => _UpgradePageState();
}

class _UpgradePageState extends State<UpgradePage> {
  PlanComparison? _plans;
  bool _loading = true;
  String? _error;
  bool _upgrading = false;

  StockRepository get _repo =>
      widget.repository ?? RepositoryScope.of(context);
  String? get _token => AuthScope.of(context).token;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_plans == null && _loading) _load();
  }

  Future<void> _load() async {
    try {
      final p = await _repo.subscriptionPlans();
      if (!mounted) return;
      setState(() {
        _plans = p;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not load plans.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _upgrade(Tier tier) async {
    final token = _token;
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to upgrade.')),
      );
      return;
    }
    final entitlements = EntitlementsScope.maybeOf(context);
    setState(() => _upgrading = true);
    try {
      await _repo.upgrade(token, tier);
      await entitlements?.refresh(token);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You are now on ${tier.label}.')),
      );
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Upgrade failed. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _upgrading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = EntitlementsScope.entitlements(context).tier;
    return Scaffold(
      appBar: AppBar(title: const Text('Plans & Upgrade')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    key: const Key('upgrade_error'),
                    child: Text(_error!),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _CurrentPlanCard(tier: current),
                      const SizedBox(height: 16),
                      for (final pt in _plans!.tiers)
                        _PlanCard(
                          plan: pt,
                          current: current,
                          busy: _upgrading,
                          onUpgrade: () => _upgrade(pt.tier),
                        ),
                      const SizedBox(height: 16),
                      _ComparisonTable(features: _plans!.features),
                      const SizedBox(height: 24),
                      const Text(
                        'TradeWizz is a research, AI-analysis and simulation '
                        'platform. No broker connection or real-money trading '
                        'is involved in any plan.',
                        key: Key('upgrade_disclaimer'),
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _CurrentPlanCard extends StatelessWidget {
  const _CurrentPlanCard({required this.tier});
  final Tier tier;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('current_plan_card'),
      color: AppColors.seed.withValues(alpha: 0.08),
      child: ListTile(
        leading: const Icon(Icons.workspace_premium, color: AppColors.seed),
        title: const Text('Current plan'),
        subtitle: Text(tier.label,
            key: const Key('current_plan_label'),
            style: const TextStyle(
                fontWeight: FontWeight.w800, fontSize: 18)),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.current,
    required this.busy,
    required this.onUpgrade,
  });

  final PlanTier plan;
  final Tier current;
  final bool busy;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final isCurrent = plan.tier == current;
    final isDowngrade = plan.tier.rank < current.rank;
    final price = plan.priceUsdMonth == 0
        ? 'Free'
        : '\$${plan.priceUsdMonth.toStringAsFixed(2)}/mo';
    return Card(
      key: Key('plan_card_${plan.tier.code}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(plan.tier.label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 18)),
                const Spacer(),
                Text(price,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16)),
              ],
            ),
            const SizedBox(height: 4),
            Text(plan.description,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: isCurrent
                  ? OutlinedButton(
                      key: Key('plan_current_${plan.tier.code}'),
                      onPressed: null,
                      child: const Text('Current plan'),
                    )
                  : isDowngrade
                      ? const SizedBox.shrink()
                      : FilledButton(
                          key: Key('upgrade_button_${plan.tier.code}'),
                          onPressed: busy ? null : onUpgrade,
                          child: Text('Upgrade to ${plan.tier.label}'),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComparisonTable extends StatelessWidget {
  const _ComparisonTable({required this.features});
  final List<PlanFeatureRow> features;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('comparison_table'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8, left: 4),
              child: Text('Feature comparison',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            Row(children: const [
              Expanded(flex: 4, child: Text('')),
              Expanded(child: Center(child: Text('Free'))),
              Expanded(child: Center(child: Text('Pro'))),
              Expanded(child: Center(child: Text('Elite'))),
            ]),
            const Divider(),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(flex: 4, child: Text(f.label)),
                  Expanded(child: Center(child: _tick(f.tiers[Tier.free]))),
                  Expanded(child: Center(child: _tick(f.tiers[Tier.pro]))),
                  Expanded(child: Center(child: _tick(f.tiers[Tier.elite]))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tick(bool? on) => Icon(
        (on ?? false) ? Icons.check_circle : Icons.remove,
        size: 18,
        color: (on ?? false) ? AppColors.up : Colors.grey.shade400,
      );
}
