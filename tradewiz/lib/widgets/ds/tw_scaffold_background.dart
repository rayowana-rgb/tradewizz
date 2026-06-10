import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Deep indigo "wizard terminal" backdrop.
///
/// A dark violet base with a soft radial glow toward the top so hero content
/// reads as floating in front of a lit stage (matches the app-icon lighting).
/// Presentation-only: wrap any screen body in this for a consistent dark scene.
class TWScaffoldBackground extends StatelessWidget {
  const TWScaffoldBackground({
    super.key,
    required this.child,
    this.glow = true,
  });

  final Widget child;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: TWColors.bgBase),
      child: Stack(
        children: [
          if (glow)
            const Positioned(
              top: -160,
              left: 0,
              right: 0,
              height: 420,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.6),
                    radius: 1.1,
                    colors: [Color(0x332B2350), Color(0x00221B3D)],
                  ),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}
