import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Primary action — electric-blue gradient with soft accent glow and a gentle
/// press-scale micro-spring. The one "loud" interactive element per screen.
class TWGradientButton extends StatefulWidget {
  const TWGradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 52,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  State<TWGradientButton> createState() => _TWGradientButtonState();
}

class _TWGradientButtonState extends State<TWGradientButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final child = AnimatedScale(
      scale: _pressed ? 0.97 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Container(
        height: widget.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: TWSpace.xl),
        decoration: BoxDecoration(
          gradient: enabled
              ? TWColors.accentGradient
              : const LinearGradient(
                  colors: [TWColors.bgElevated, TWColors.bgElevated]),
          borderRadius: TWRadius.rButton,
          boxShadow: enabled ? TWShadow.accentGlow : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon, size: 18, color: Colors.white),
              const SizedBox(width: TWSpace.sm),
            ],
            Text(widget.label,
                style: TWType.label.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );

    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onPressed,
      child: widget.expand
          ? SizedBox(width: double.infinity, child: child)
          : child,
    );
  }
}

/// Secondary action — transparent with a hairline border and accent text.
class TWGhostButton extends StatelessWidget {
  const TWGhostButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 52,
    this.expand = true,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final child = Container(
      height: height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.xl),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: TWRadius.rButton,
        border: Border.all(color: TWColors.hairlineEdge, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: TWColors.accentBright),
            const SizedBox(width: TWSpace.sm),
          ],
          Text(label,
              style: TWType.label.copyWith(color: TWColors.accentBright)),
        ],
      ),
    );
    return GestureDetector(
      onTap: onPressed,
      child: expand ? SizedBox(width: double.infinity, child: child) : child,
    );
  }
}
