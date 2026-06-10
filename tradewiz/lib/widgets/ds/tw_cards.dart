import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Floating opaque surface card — the workhorse for lists/sections.
///
/// Soft ambient shadow + a top-light hairline gradient border gives the
/// "embossed glass" feel from the icon without the cost of a real blur. Use
/// this in long scrolling lists for performance.
class TWFloatingCard extends StatefulWidget {
  const TWFloatingCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TWSpace.xl),
    this.radius = TWRadius.card,
    this.onTap,
    this.glow = false,
    this.gradient,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  /// Adds the accent glow (use sparingly: hero / AI cards only).
  final bool glow;

  /// Optional surface gradient (e.g. portfolio hero). Falls back to solid card.
  final Gradient? gradient;

  @override
  State<TWFloatingCard> createState() => _TWFloatingCardState();
}

class _TWFloatingCardState extends State<TWFloatingCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    final shadows = <BoxShadow>[
      ...(_pressed ? TWShadow.ambientSm : TWShadow.ambient),
      if (widget.glow) ...TWShadow.accentGlow,
    ];

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      transform: _pressed
          ? (Matrix4.identity()..scaleByDouble(0.98, 0.98, 1.0, 1.0))
          : Matrix4.identity(),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.gradient == null ? TWColors.surfaceCard : null,
        gradient: widget.gradient,
        borderRadius: radius,
        border: Border.all(color: TWColors.hairlineTop, width: 1),
        boxShadow: shadows,
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    if (widget.onTap == null) return card;
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: card,
    );
  }
}

/// True glass card — backdrop blur + translucent fill. Reserve for heroes and
/// overlays where it sits over a gradient/content. Heavier than [TWFloatingCard].
class TWGlassCard extends StatelessWidget {
  const TWGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TWSpace.xl),
    this.radius = TWRadius.cardLg,
    this.glow = false,
    this.blur = 18,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool glow;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          ...TWShadow.ambient,
          if (glow) ...TWShadow.accentGlow,
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              color: TWColors.surfaceCardGlass,
              borderRadius: r,
              border: Border.all(color: TWColors.hairlineTop, width: 1),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
