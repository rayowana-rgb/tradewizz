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
        gradient: const RadialGradient(
          center: Alignment(-0.4, -0.5),
          radius: 1.1,
          colors: [TWColors.accentBright, TWColors.accent],
        ),
        boxShadow: glow ? TWShadow.accentGlow : null,
        border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
      ),
      child: Center(
        child: Icon(
          Icons.auto_awesome, // wizard "spark" stand-in (no external icon pkg)
          size: size * 0.5,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Alias kept for spec parity ("WizardMark").
class WizardMark extends TWAiOrb {
  const WizardMark({super.key, super.size, super.glow});
}
