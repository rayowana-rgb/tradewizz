import 'package:flutter/widgets.dart';

import 'activation_metrics.dart';

/// Exposes [ActivationMetrics] to the widget tree (Phase I).
class ActivationScope extends InheritedNotifier<ActivationMetrics> {
  const ActivationScope({
    super.key,
    required ActivationMetrics metrics,
    required super.child,
  }) : super(notifier: metrics);

  static ActivationMetrics of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ActivationScope>();
    return scope?.notifier ?? ActivationMetrics();
  }

  static ActivationMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ActivationScope>()?.notifier;
}
