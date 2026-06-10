import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Animated number that rolls from its previous value to the new one.
///
/// Used for prices, scores, and portfolio values to give the "live terminal"
/// feel. Honors Reduce Motion (snaps instantly). Always tabular figures.
class TWNumberRoll extends StatefulWidget {
  const TWNumberRoll({
    super.key,
    required this.value,
    this.fractionDigits = 0,
    this.prefix = '',
    this.suffix = '',
    this.style,
    this.duration = const Duration(milliseconds: 650),
  });

  final double value;
  final int fractionDigits;
  final String prefix;
  final String suffix;
  final TextStyle? style;
  final Duration duration;

  @override
  State<TWNumberRoll> createState() => _TWNumberRollState();
}

class _TWNumberRollState extends State<TWNumberRoll> {
  late double _from = widget.value;

  @override
  void didUpdateWidget(TWNumberRoll old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _from = old.value;
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final base = TWType.tabular(widget.style ?? TWType.monoNum);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _from, end: widget.value),
      duration: reduceMotion ? Duration.zero : widget.duration,
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        '${widget.prefix}${v.toStringAsFixed(widget.fractionDigits)}${widget.suffix}',
        style: base,
      ),
    );
  }
}
