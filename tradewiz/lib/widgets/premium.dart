import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../pages/upgrade_page.dart';
import '../services/entitlements_scope.dart';
import '../theme.dart';

/// Wraps premium content. When the user lacks [requiredTier], the [child] is
/// blurred and a centered "Upgrade to X" overlay is shown; otherwise the child
/// renders normally.
class LockedFeature extends StatelessWidget {
  const LockedFeature({
    super.key,
    required this.requiredTier,
    required this.feature,
    required this.child,
    this.title,
  });

  final Tier requiredTier;
  final String feature; // feature key, for the upgrade-screen highlight
  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final unlocked =
        EntitlementsScope.entitlements(context).tier.atLeast(requiredTier);
    if (unlocked) return child;

    return Stack(
      children: [
        // Blurred, non-interactive preview of the locked content.
        Positioned.fill(
          child: ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: IgnorePointer(child: child),
            ),
          ),
        ),
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(alpha: 0.04),
            child: Center(
              child: UpgradeBadge(
                requiredTier: requiredTier,
                feature: feature,
                label: title,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small "Upgrade to PRO/ELITE" call-to-action that opens the upgrade screen.
class UpgradeBadge extends StatelessWidget {
  const UpgradeBadge({
    super.key,
    required this.requiredTier,
    required this.feature,
    this.label,
  });

  final Tier requiredTier;
  final String feature;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_outline, color: AppColors.seed),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(label!, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
        const SizedBox(height: 8),
        FilledButton.icon(
          key: Key('upgrade_cta_${requiredTier.code}'),
          icon: const Icon(Icons.workspace_premium, size: 18),
          label: Text('Upgrade to ${requiredTier.label}'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => UpgradePage(highlightFeature: feature),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small chip showing the current tier (e.g. in the Account header).
class TierChip extends StatelessWidget {
  const TierChip({super.key});

  @override
  Widget build(BuildContext context) {
    final tier = EntitlementsScope.entitlements(context).tier;
    final color = tier == Tier.elite
        ? Colors.amber.shade800
        : tier == Tier.pro
            ? AppColors.seed
            : Colors.grey;
    return Chip(
      key: const Key('tier_chip'),
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.workspace_premium, size: 16, color: color),
      label: Text(tier.label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }
}
