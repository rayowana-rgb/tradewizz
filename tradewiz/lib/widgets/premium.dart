import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/subscription.dart';
import '../pages/upgrade_page.dart';
import '../services/entitlements_scope.dart';
import '../theme.dart';

/// Wraps premium content.
///
/// PREVIEW MODE (PRO/ELITE Preview pivot): the [child] renders fully and stays
/// interactive; a small "PRO PREVIEW" / "ELITE PREVIEW" badge is overlaid so
/// the user knows it's an early-access feature. No blur, no hard paywall.
///
/// When preview mode is OFF (the dormant paywall is re-armed) and the user
/// lacks [requiredTier], the child is blurred behind an Upgrade overlay.
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
    final ent = EntitlementsScope.entitlements(context);

    // Preview pivot: everything is openable; just badge preview features.
    if (ent.preview) {
      final badge = ent.previewBadgeFor(feature);
      if (badge.isEmpty) return child;
      return Stack(
        children: [
          child,
          Positioned(
            top: 0,
            right: 0,
            child: PreviewBadge(label: badge),
          ),
        ],
      );
    }

    final unlocked = ent.tier.atLeast(requiredTier);
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

/// A small "PRO PREVIEW" / "ELITE PREVIEW" pill overlaid on preview features.
class PreviewBadge extends StatelessWidget {
  const PreviewBadge({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final elite = label.startsWith('ELITE');
    final color = elite ? Colors.amber.shade800 : AppColors.seed;
    return Container(
      key: Key('preview_badge_${elite ? 'ELITE' : 'PRO'}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(10),
          bottomLeft: Radius.circular(10),
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.science_outlined, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(
                color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      ]),
    );
  }
}

/// A small chip showing the current tier (e.g. in the Account header). During
/// the preview phase a FREE user is labelled "Preview".
class TierChip extends StatelessWidget {
  const TierChip({super.key});

  @override
  Widget build(BuildContext context) {
    final ent = EntitlementsScope.entitlements(context);
    final tier = ent.tier;
    final color = tier == Tier.elite
        ? Colors.amber.shade800
        : tier == Tier.pro
            ? AppColors.seed
            : Colors.grey;
    final label = (ent.preview && tier == Tier.free) ? 'Preview' : tier.label;
    return Chip(
      key: const Key('tier_chip'),
      visualDensity: VisualDensity.compact,
      avatar: Icon(Icons.workspace_premium, size: 16, color: color),
      label: Text(label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }
}
