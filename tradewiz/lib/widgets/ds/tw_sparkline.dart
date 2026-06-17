import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Minimal sparkline (no axes/labels). Gradient stroke colored up/down with a
/// soft area fill. If [points] is empty it draws a flat neutral baseline so it
/// never collapses to empty space.
class TWSparkline extends StatelessWidget {
  const TWSparkline({
    super.key,
    required this.points,
    this.height = 36,
    this.width,
    this.up,
    this.referenceValue,
  });

  final List<double> points;
  final double height;
  final double? width;

  /// Force direction color; otherwise inferred from first vs last point.
  final bool? up;

  /// Optional value for a dashed horizontal reference line (e.g. the previous
  /// close). Drawn in a muted neutral tone, Stockbit-style. Null hides it.
  final double? referenceValue;

  @override
  Widget build(BuildContext context) {
    final isUp = up ??
        (points.length >= 2 ? points.last >= points.first : true);
    final color = isUp ? TWColors.up : TWColors.down;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SparkPainter(
          points: points,
          color: color,
          referenceValue: referenceValue,
        ),
        size: Size(width ?? double.infinity, height),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.points,
    required this.color,
    this.referenceValue,
  });
  final List<double> points;
  final Color color;
  final double? referenceValue;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    if (points.length < 2) {
      // Flat neutral baseline so the tile never looks broken/empty.
      final y = size.height * 0.5;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        stroke..color = TWColors.neutral.withValues(alpha: 0.4),
      );
      return;
    }

    // Include the reference value in the min/max so the dashed line stays in
    // view even when it sits just outside the visible price range.
    var minV = points.reduce((a, b) => a < b ? a : b);
    var maxV = points.reduce((a, b) => a > b ? a : b);
    final ref = referenceValue;
    if (ref != null) {
      if (ref < minV) minV = ref;
      if (ref > maxV) maxV = ref;
    }
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    final dx = size.width / (points.length - 1);

    double yFor(double v) {
      final norm = (v - minV) / range;
      return size.height - norm * size.height;
    }

    Offset at(int i) => Offset(dx * i, yFor(points[i]));

    final path = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(at(i).dx, at(i).dy);
    }

    // Area fill.
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0.0)],
        ).createShader(Offset.zero & size),
    );
    // Dashed previous-close reference line (pro-trader convention) drawn UNDER
    // the stroke so the price line stays the focal point.
    if (ref != null) {
      final refY = yFor(ref);
      final dashPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = TWColors.textTertiary.withValues(alpha: 0.55);
      const dashW = 4.0;
      const gapW = 3.0;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, refY),
          Offset((x + dashW).clamp(0, size.width), refY),
          dashPaint,
        );
        x += dashW + gapW;
      }
    }

    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.points != points ||
      old.color != color ||
      old.referenceValue != referenceValue;
}
