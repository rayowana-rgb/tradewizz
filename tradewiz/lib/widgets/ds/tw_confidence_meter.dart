import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Horizontal confidence meter — an animated gradient bar with a label.
///
/// Distinct from [TWScoreRing]/[TWConfidencePill]: use this on the Analysis
/// and Stock Detail screens where a wide, scannable strength bar reads better
/// than a compact ring. Confidence is framed as research strength, not a
/// recommendation (compliance).
class TWConfidenceMeter extends StatelessWidget {
  const TWConfidenceMeter({
    super.key,
    required this.value, // 0..100
    this.label = 'Confidence',
    this.showValue = true,
  });

  final double value;
  final String label;
  final bool showValue;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0, 100).toDouble();
    final color = TWColors.confidence(v);
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TWType.overline),
            if (showValue)
              Text('${v.toStringAsFixed(0)}%',
                  style: TWType.tabular(TWType.label).copyWith(color: color)),
          ],
        ),
        const SizedBox(height: TWSpace.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            return Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: TWColors.ringTrack,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: v / 100),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => Container(
                    height: 8,
                    width: maxW * t,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [color.withValues(alpha: 0.7), color],
                      ),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.45),
                          blurRadius: 12,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
