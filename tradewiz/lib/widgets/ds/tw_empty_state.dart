import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';
import 'tw_ai_orb.dart';
import 'tw_buttons.dart';
import 'tw_cards.dart';

/// Mature, on-brand empty state: the Wizz orb mascot + title + body + optional
/// CTA, wrapped in a floating card so it never reads as flat grey space.
class TWEmptyState extends StatelessWidget {
  const TWEmptyState({
    super.key,
    required this.title,
    this.body,
    this.ctaLabel,
    this.onCta,
    this.icon,
    this.boxed = true,
  });

  final String title;
  final String? body;
  final String? ctaLabel;
  final VoidCallback? onCta;

  /// Optional override glyph; defaults to the Wizz orb.
  final IconData? icon;
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (icon == null)
          const TWAiOrb(size: 48)
        else
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: TWColors.accent.withValues(alpha: 0.14),
              border: Border.all(color: TWColors.accent.withValues(alpha: 0.3)),
            ),
            child: Icon(icon, color: TWColors.accentBright, size: 24),
          ),
        const SizedBox(height: TWSpace.lg),
        Text(title, textAlign: TextAlign.center, style: TWType.title3),
        if (body != null) ...[
          const SizedBox(height: TWSpace.sm),
          Text(body!,
              textAlign: TextAlign.center,
              style: TWType.bodySm.copyWith(color: TWColors.textTertiary)),
        ],
        if (ctaLabel != null && onCta != null) ...[
          const SizedBox(height: TWSpace.lg),
          TWGradientButton(label: ctaLabel!, onPressed: onCta, expand: false),
        ],
      ],
    );

    if (!boxed) return Center(child: content);
    return TWFloatingCard(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.xl, vertical: TWSpace.xxl),
      child: Center(child: content),
    );
  }
}
