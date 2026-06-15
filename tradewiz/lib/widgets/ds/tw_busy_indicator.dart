import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// A labeled busy indicator for heavy operations (screening, analyzing,
/// fetching/building snapshots). Instead of a bare spinner that reads like a
/// stall, it shows a spinner plus a short title and optional subtext so a
/// slow-but-healthy backend (e.g. a cold-cache rebuild) reads as in-progress.
class TWBusyIndicator extends StatelessWidget {
  const TWBusyIndicator({
    super.key,
    this.title = 'Loading\u2026',
    this.subtitle,
    this.size = 32,
    this.strokeWidth = 3,
    this.boxed = true,
  });

  /// Primary line, e.g. 'Screening the market…'.
  final String title;

  /// Optional reassuring detail, e.g. 'This can take a moment.'.
  final String? subtitle;

  final double size;
  final double strokeWidth;

  /// When true, centers and pads the content to fill the available space.
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            color: TWColors.accentBright,
            strokeWidth: strokeWidth,
          ),
        ),
        const SizedBox(height: TWSpace.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: TWType.label.copyWith(color: TWColors.textPrimary),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: TWType.caption.copyWith(color: TWColors.textSecondary),
          ),
        ],
      ],
    );
    if (!boxed) return content;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: content,
      ),
    );
  }
}
