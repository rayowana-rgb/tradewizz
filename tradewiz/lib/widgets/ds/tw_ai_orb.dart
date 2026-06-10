import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// The TradeWizz AI brand mark — a glossy gradient orb carrying a simplified
/// wizard-hat glyph (echoes the app icon). Used as the AI avatar / mascot.
/// Reserved for AI/Wizz contexts; never decorative.
class TWAiOrb extends StatelessWidget {
  const TWAiOrb({super.key, this.size = 36, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // Warm plum orb (icon squircle), lit from the upper-left.
        gradient: const RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.15,
          colors: [Color(0xFF4A3F52), Color(0xFF2E2733)],
        ),
        boxShadow: glow ? TWShadow.wizardGlow : null,
        // Dark-navy charcoal outline like the icon glyph edges.
        border: Border.all(color: TWColors.outlineNavy.withValues(alpha: 0.6)),
      ),
      child: Center(
        child: Icon(
          // White wizard "spark" glyph (no external icon pkg); echoes the
          // icon's white-on-plum wizard identity.
          Icons.auto_awesome,
          size: size * 0.5,
          color: TWColors.wizardWhite,
        ),
      ),
    );
  }
}

/// Alias kept for spec parity ("WizardMark").
class WizardMark extends TWAiOrb {
  const WizardMark({super.key, super.size, super.glow});
}
