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
  });

  final List<double> points;
  final double height;
  final double? width;

  /// Force direction color; otherwise inferred from first vs last point.
  final bool? up;

  @override
  Widget build(BuildContext context) {
    final isUp = up ??
        (points.length >= 2 ? points.last >= points.first : true);
    final color = isUp ? TWColors.up : TWColors.down;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _SparkPainter(points: points, color: color),
        size: Size(width ?? double.infinity, height),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.points, required this.color});
  final List<double> points;
  final Color color;

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

    final minV = points.reduce((a, b) => a < b ? a : b);
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    final dx = size.width / (points.length - 1);

    Offset at(int i) {
      final norm = (points[i] - minV) / range;
      return Offset(dx * i, size.height - norm * size.height);
    }

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
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.points != points || old.color != color;
}
