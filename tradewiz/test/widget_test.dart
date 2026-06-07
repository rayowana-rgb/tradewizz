import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/main.dart';

void main() {
  testWidgets('TradeWiz shell renders with navigation', (tester) async {
    await tester.pumpWidget(const TradeWizApp());

    // Dashboard is the default tab.
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Watchlist'), findsWidgets);
    expect(find.text('AI Analysis'), findsWidgets);

    // Switch to the AI Analysis tab.
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Analyze a Stock'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Stock symbol'), findsOneWidget);
  });

  testWidgets('bottom navigation has the 5 expected tabs and no Portfolio',
      (tester) async {
    await tester.pumpWidget(const TradeWizApp());
    await tester.pumpAndSettle();

    final navBar = find.byType(NavigationBar);
    expect(navBar, findsOneWidget);

    // The five destinations, in order.
    for (final label in [
      'Dashboard',
      'Screener',
      'Watchlist',
      'AI Analysis',
      'Account',
    ]) {
      expect(
        find.descendant(of: navBar, matching: find.text(label)),
        findsOneWidget,
        reason: 'expected "$label" destination in bottom navigation',
      );
    }

    // Portfolio is no longer a bottom-navigation destination.
    expect(
      find.descendant(of: navBar, matching: find.text('Portfolio')),
      findsNothing,
    );
    // And its old icon is gone from the nav bar.
    expect(
      find.descendant(
          of: navBar, matching: find.byIcon(Icons.pie_chart_outline)),
      findsNothing,
    );
  });
}
