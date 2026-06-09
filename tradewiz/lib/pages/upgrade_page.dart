import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../repositories/stock_repository.dart';
import '../services/auth_scope.dart';
import '../services/entitlements_scope.dart';
import '../services/repository_scope.dart';
import '../theme.dart';

/// Phase 7 — the premium / early-access screen.
///
/// PRO/ELITE Preview pivot: TradeWizz is in preview, so this screen shows NO
/// prices and NO purchase flow. Instead of "Upgrade", users "Join Waiting
/// List" for early access; we only record the intent. Pure research/AI/
/// simulation product: there is NO broker or real-money feature here, and no
/// Stripe / app-store billing.
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

  /// Join the early-access waiting list for [tier]. No payment is taken.
  Future<void> _joinWaitlist(Tier tier) async {
    final token = _token;
    if (token == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to join the waiting list.')),
      );
      return;
    }
    setState(() => _upgrading = true);
    try {
      await _repo.joinWaitlist(token, tier);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const Key('waitlist_dialog'),
          title: Text('TradeWizz ${tier.label} is in preview'),
          content: Text(
            'TradeWizz ${tier.label} is currently in preview.\n\n'
            'You have been added to the early-access waiting list.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Got it'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not join the waiting list. Try again.')),
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
                      const SizedBox(height: 12),
                      const _PreviewBanner(),
                      const SizedBox(height: 16),
                      for (final pt in _plans!.tiers)
                        _PlanCard(
                          plan: pt,
                          current: current,
                          busy: _upgrading,
                          onJoin: () => _joinWaitlist(pt.tier),
                        ),
                      const SizedBox(height: 16),
                      _ComparisonTable(features: _plans!.features),
                      const SizedBox(height: 24),
                      const Text(
                        'TradeWizz is a research, AI-analysis and simulation '
                        'platform. It is currently in preview: all features are '
                        'open and there is no payment. No broker connection or '
                        'real-money trading is involved in any plan.',
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

class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner();

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('preview_banner'),
      color: AppColors.seed.withValues(alpha: 0.06),
      child: const Padding(
        padding: EdgeInsets.all(14),
        child: Row(children: [
          Icon(Icons.science_outlined, color: AppColors.seed),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'TradeWizz PRO & ELITE are in preview. Every feature is open to '
              'you right now — join the waiting list to get early access news.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.current,
    required this.busy,
    required this.onJoin,
  });

  final PlanTier plan;
  final Tier current;
  final bool busy;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    // Preview pivot: no prices anywhere. FREE shows an info chip; PRO/ELITE
    // show a "Join Waiting List" CTA. No purchase, ever.
    final isFree = plan.tier == Tier.free;
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
                if (!isFree)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.seed.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${plan.tier.label.toUpperCase()} PREVIEW',
                        style: const TextStyle(
                            color: AppColors.seed,
                            fontWeight: FontWeight.w800,
                            fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(plan.description,
                style: const TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: isFree
                  ? OutlinedButton(
                      key: const Key('plan_current_FREE'),
                      onPressed: null,
                      child: const Text('Included for everyone'),
                    )
                  : FilledButton.icon(
                      key: Key('waitlist_button_${plan.tier.code}'),
                      icon: const Icon(Icons.notifications_active_outlined,
                          size: 18),
                      onPressed: busy ? null : onJoin,
                      label: const Text('Join Waiting List'),
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
