import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Shimmer loading primitives for the Wizard Terminal.
///
/// A single [TWSkeleton] box plus a [TWSkeletonGroup] that paints a moving
/// highlight band across all descendants. Respects `MediaQuery.disableAnimations`
/// (Reduce Motion) by falling back to a static muted fill.
class TWSkeleton extends StatelessWidget {
  const TWSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = TWRadius.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: TWColors.bgElevated,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Wraps skeletons and sweeps a soft highlight across them.
class TWSkeletonGroup extends StatefulWidget {
  const TWSkeletonGroup({super.key, required this.child});

  final Widget child;

  @override
  State<TWSkeletonGroup> createState() => _TWSkeletonGroupState();
}

class _TWSkeletonGroupState extends State<TWSkeletonGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) return widget.child;

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final dx = rect.width * (t * 2 - 0.5);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Color(0x00FFFFFF),
                Color(0x26FFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: const [0.35, 0.5, 0.65],
              transform: _SlideGradient(dx / rect.width),
            ).createShader(rect);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.fraction);
  final double fraction;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * fraction, 0, 0);
  }
}

/// Ready-made skeleton resembling a stock/idea glass card.
class TWCardSkeleton extends StatelessWidget {
  const TWCardSkeleton({super.key, this.height = 96});

  final double height;

  @override
  Widget build(BuildContext context) {
    return TWSkeletonGroup(
      child: Container(
        height: height,
        padding: const EdgeInsets.all(TWSpace.lg),
        decoration: BoxDecoration(
          color: TWColors.surfaceCard,
          borderRadius: TWRadius.rCard,
          border: Border.all(color: TWColors.hairline, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const TWSkeleton(width: 46, height: 46, radius: 999),
            const SizedBox(width: TWSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  TWSkeleton(width: 120, height: 14),
                  SizedBox(height: TWSpace.sm),
                  TWSkeleton(width: 200, height: 12),
                ],
              ),
            ),
            const SizedBox(width: TWSpace.lg),
            const TWSkeleton(width: 54, height: 24, radius: 999),
          ],
        ),
      ),
    );
  }
}
