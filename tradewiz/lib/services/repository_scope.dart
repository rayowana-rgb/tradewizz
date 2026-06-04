import 'package:flutter/widgets.dart';

import '../repositories/stock_repository.dart';

/// Provides a [StockRepository] to the widget tree so pages (and pushed routes
/// like the analysis detail) share one configured instance.
class RepositoryScope extends InheritedWidget {
  const RepositoryScope({
    super.key,
    required this.repository,
    required super.child,
  });

  final StockRepository repository;

  /// Returns the provided repository, or a default one if no scope exists
  /// (keeps widgets usable in isolation).
  static StockRepository of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<RepositoryScope>();
    return scope?.repository ?? StockRepository();
  }

  @override
  bool updateShouldNotify(RepositoryScope oldWidget) =>
      oldWidget.repository != repository;
}
