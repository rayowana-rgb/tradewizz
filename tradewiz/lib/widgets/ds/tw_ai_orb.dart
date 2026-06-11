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
        // Rounded-square (squircle) indigo->violet mark, lit from the
        // upper-left like the reference sparkle badge.
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF5B4FCF), Color(0xFF3D2C8D)],
        ),
        boxShadow: glow ? TWShadow.wizardGlow : null,
        // Soft top highlight edge for the glossy badge look.
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
          width: 1,
        ),
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
