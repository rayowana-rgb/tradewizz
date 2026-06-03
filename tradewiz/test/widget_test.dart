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
}
