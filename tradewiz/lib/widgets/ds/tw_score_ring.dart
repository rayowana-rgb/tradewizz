import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Circular confidence/score ring (0..100). Sweep colored by the confidence
/// ramp (down -> warn -> up); the centre shows the score in tabular figures.
class TWScoreRing extends StatelessWidget {
  const TWScoreRing({
    super.key,
    required this.score,
    this.size = 56,
    this.stroke = 5,
    this.label,
  });

  final double score;
  final double size;
  final double stroke;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final clamped = score.clamp(0, 100).toDouble();
    final color = TWColors.confidence(clamped);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(progress: clamped / 100, color: color, stroke: stroke),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(clamped.toStringAsFixed(0),
                  style: TWType.tabular(TWType.title3).copyWith(color: Colors.white)),
              if (label != null)
                Text(label!, style: TWType.overline.copyWith(fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color, required this.stroke});
  final double progress;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = TWColors.ringTrack;
    canvas.drawCircle(center, radius, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: -math.pi / 2,
        endAngle: 3 * math.pi / 2,
        colors: [color.withValues(alpha: 0.6), color],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress || old.color != color || old.stroke != stroke;
}

/// Compact pill alternative to the ring: "Confidence 92" with a ramp dot.
class TWConfidencePill extends StatelessWidget {
  const TWConfidencePill({
    super.key,
    required this.score,
    this.caption = 'Confidence',
  });

  final double score;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final color = TWColors.confidence(score);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: TWRadius.rChip,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: TWSpace.sm),
          Text(caption,
              style: TWType.caption.copyWith(color: TWColors.textSecondary)),
          const SizedBox(width: 6),
          Text(score.toStringAsFixed(0),
              style: TWType.tabular(TWType.label).copyWith(color: color)),
        ],
      ),
    );
  }
}
