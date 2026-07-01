import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Floating surface card — the workhorse for lists/sections.
///
/// Unified with the Home "My Portfolio" premium language: a soft violet-indigo
/// gradient surface, top-light highlight sheen, hairline border, and deep
/// ambient shadow — the same ecosystem as [TWPremiumCard] but calmer (no loud
/// electric-blue corner) so it works for dense, repeated content. Radius 24.
class TWFloatingCard extends StatefulWidget {
  const TWFloatingCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TWSpace.lg),
    this.radius = TWRadius.premium,
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

  /// Optional surface gradient override. Defaults to the subtle dark indigo
  /// surface ([TWColors.briefGradient], matching Morning Brief); pass
  /// [TWColors.portfolioGradient] for the signature blue-corner hero look.
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
    final gradient = widget.gradient ?? TWColors.briefGradient;

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      clipBehavior: Clip.antiAlias,
      transform: _pressed
          ? (Matrix4.identity()..scaleByDouble(0.98, 0.98, 1.0, 1.0))
          : Matrix4.identity(),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: radius,
        border: Border.all(color: TWColors.hairlineTop, width: 1),
        boxShadow: shadows,
      ),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 56,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.06),
                      Colors.white.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: widget.padding, child: widget.child),
        ],
      ),
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

/// Premium gradient surface — the single source of truth derived from the Home
/// "My Portfolio" card: violet-indigo gradient, top-light hairline border, deep
/// ambient drop + soft accent glow, radius 24, generous internal padding.
///
/// Use [TWPremiumCard] for any hero / signature section so the whole app reads
/// as one ecosystem. Pass [glow] = false to drop the accent glow for calmer,
/// dense content cards, and override [gradient] for the full blue-corner
/// signature ([TWColors.portfolioGradient]).
class TWPremiumCard extends StatefulWidget {
  const TWPremiumCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TWSpace.xl),
    this.radius = TWRadius.premium,
    this.onTap,
    this.glow = true,
    this.gradient = TWColors.premiumGradient,
    this.topHighlight = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  /// Soft accent glow (true for heroes; false for calmer dense cards).
  final bool glow;

  /// Surface gradient. Defaults to the softer premium gradient; pass
  /// [TWColors.portfolioGradient] for the full signature blue-corner look.
  final Gradient gradient;

  /// Subtle top-light highlight sheen across the top edge.
  final bool topHighlight;

  @override
  State<TWPremiumCard> createState() => _TWPremiumCardState();
}

class _TWPremiumCardState extends State<TWPremiumCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.radius);
    final shadows = <BoxShadow>[
      ...TWShadow.ambient,
      if (widget.glow) ...TWShadow.accentGlow,
    ];

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      clipBehavior: Clip.antiAlias,
      transform: _pressed
          ? (Matrix4.identity()..scaleByDouble(0.985, 0.985, 1.0, 1.0))
          : Matrix4.identity(),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: widget.gradient,
        borderRadius: radius,
        border: Border.all(color: TWColors.hairlineTop, width: 1),
        boxShadow: shadows,
      ),
      child: Stack(
        children: [
          if (widget.topHighlight)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 64,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.07),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Padding(padding: widget.padding, child: widget.child),
        ],
      ),
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
    this.padding = const EdgeInsets.all(TWSpace.lg),
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

/// Flat "garis-garis" section — no card frame, no shadow, no gradient. Just a
/// bottom hairline so a stack of them reads as one continuous list (matching
/// the Home ideas/list style). Use in place of [TWFloatingCard] where the
/// design calls for flat rows instead of elevated cards.
class TWFlatSection extends StatelessWidget {
  const TWFlatSection({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(
        horizontal: TWSpace.sm, vertical: TWSpace.md),
    this.divider = true,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Draws the bottom hairline that separates this section from the next.
  final bool divider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      width: double.infinity,
      decoration: divider
          ? const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: TWColors.hairlineTop, width: 1),
              ),
            )
          : null,
      padding: padding,
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, child: content),
    );
  }
}
