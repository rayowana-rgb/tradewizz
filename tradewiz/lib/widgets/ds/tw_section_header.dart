import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Section header: optional uppercase eyebrow + title + optional trailing
/// action. Keeps generous vertical rhythm.
class TWSectionHeader extends StatelessWidget {
  const TWSectionHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.trailing,
  });

  final String title;
  final String? eyebrow;
  final Widget? trailing;

  Widget? get _eyebrowWidget => eyebrow == null
      ? null
      : Text(eyebrow!.toUpperCase(), style: TWType.overline);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: TWSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?_eyebrowWidget,
                Text(title, style: TWType.title2),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Standalone uppercase eyebrow label.
class TWEyebrow extends StatelessWidget {
  const TWEyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TWType.overline.copyWith(color: color),
      );
}
