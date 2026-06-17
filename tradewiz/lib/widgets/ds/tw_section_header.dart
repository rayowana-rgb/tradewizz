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
/// a thin accent bar on the left and a single bold title. Demarcates where a
/// new section starts against the page background without adding a full card.
/// Stays within the locked type scale (title uses [TWType.title2] = 20px).
class TWBandedSectionHeader extends StatelessWidget {
  const TWBandedSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.accent,
  });

  final String title;

  /// Optional trailing action (e.g. a "See all" text button).
  final Widget? trailing;

  /// Left accent-bar color. Defaults to the brand accent.
  final Color? accent;

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
          Container(
            width: 3,
            height: 18,
            decoration: BoxDecoration(
              color: accent ?? TWColors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: TWSpace.sm),
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
