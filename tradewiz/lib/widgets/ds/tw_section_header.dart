import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Section header: optional uppercase eyebrow + title + optional trailing
/// action. Keeps generous vertical rhythm.
class TWSectionHeader extends StatelessWidget {
  const TWSectionHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.trailing,
  });

  final String title;
  final String? eyebrow;
  final Widget? trailing;

  Widget? get _eyebrowWidget => eyebrow == null
      ? null
      : Text(eyebrow!.toUpperCase(), style: TWType.overline);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TWSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?_eyebrowWidget,
                Text(title, style: TWType.title2),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Banded section header (Stockbit-style): a subtle full-width tonal band with
/// a single bold title in a faint banded strip. Demarcates where a new section
/// starts against the page background without adding a full card.
/// Stays within the locked type scale (title uses [TWType.title2] = 20px).
class TWBandedSectionHeader extends StatelessWidget {
  const TWBandedSectionHeader({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;

  /// Optional trailing action (e.g. a "See all" text button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.md),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: TWRadius.rSm,
        border: Border.all(color: TWColors.hairlineTop, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TWType.title2,
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Footer "See all" link (Stockbit-style): a full-width, centered, tappable
/// link at the bottom of a long section instead of an inline right chevron.
/// Uses the brand accent (not Stockbit green) to keep TradeWizz's identity.
class TWSeeAllFooter extends StatelessWidget {
  const TWSeeAllFooter({
    super.key,
    required this.onTap,
    this.label = 'See all',
  });

  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: TWRadius.rSm,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: TWSpace.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TWType.bodySm.copyWith(
                color: TWColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: TWSpace.xs),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: TWColors.accent),
          ],
        ),
      ),
    );
  }
}

/// Standalone uppercase eyebrow label.
class TWEyebrow extends StatelessWidget {
  const TWEyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TWType.overline.copyWith(color: color),
      );
}
