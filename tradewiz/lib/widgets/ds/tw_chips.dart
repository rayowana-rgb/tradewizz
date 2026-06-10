import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Gain/loss chip with a directional caret and tabular figures.
/// Pass [percent]; optionally a leading [value] string (already formatted).
class TWDeltaChip extends StatelessWidget {
  const TWDeltaChip({
    super.key,
    required this.percent,
    this.value,
    this.compact = false,
  });

  /// Signed percent, e.g. -1.24 or +2.0.
  final double percent;

  /// Optional pre-formatted absolute change (e.g. "+35.40").
  final String? value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final up = percent >= 0;
    final color = up ? TWColors.up : TWColors.down;
    final bg = up ? TWColors.upSoft : TWColors.downSoft;
    final sign = up ? '+' : '';
    final pctText = '$sign${percent.toStringAsFixed(2)}%';
    final text = value == null ? pctText : '$value  ($pctText)';
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: compact ? TWSpace.sm : TWSpace.md,
          vertical: compact ? 3 : TWSpace.xs + 1),
      decoration: BoxDecoration(color: bg, borderRadius: TWRadius.rChip),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
              size: compact ? 12 : 14, color: color),
          const SizedBox(width: 3),
          Text(text,
              style: TWType.tabular(TWType.label).copyWith(color: color)),
        ],
      ),
    );
  }
}

/// Signal pill (BUY / SELL / WATCH) tinted by stance.
class TWSignalPill extends StatelessWidget {
  const TWSignalPill({super.key, required this.signal});
  final String signal;

  @override
  Widget build(BuildContext context) {
    final s = signal.toUpperCase();
    final isBuy = s.contains('BUY');
    final isSell = s.contains('SELL');
    final color = isBuy
        ? TWColors.up
        : (isSell ? TWColors.down : TWColors.warn);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: TWSpace.md, vertical: TWSpace.xs),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: TWRadius.rChip,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(s,
          style: TWType.overline.copyWith(color: color, letterSpacing: 0.8)),
    );
  }
}

/// Small neutral tag chip used for reasoning tags.
class TWTagChip extends StatelessWidget {
  const TWTagChip({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.md, vertical: 5),
      decoration: BoxDecoration(
        color: TWColors.bgElevated,
        borderRadius: TWRadius.rChip,
        border: Border.all(color: TWColors.hairlineEdge),
      ),
      child: Text(label,
          style: TWType.caption.copyWith(color: TWColors.textSecondary)),
    );
  }
}
