import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme_tradewizz.dart';

/// Floating glass navigation bar for the Wizard Terminal shell.
///
/// Wraps a real Material [NavigationBar] (kept transparent) behind a
/// backdrop-blurred, hairline-bordered glass slab. Keeping the underlying
/// [NavigationBar] means existing nav tests (`find.byType(NavigationBar)` +
/// label text) continue to resolve unchanged.
class TWGlassNavBar extends StatelessWidget {
  const TWGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    final navTheme = NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: TWColors.accent.withValues(alpha: 0.20),
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TWType.caption.copyWith(
          color: selected ? TWColors.textPrimary : TWColors.textTertiary,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? TWColors.accentBright : TWColors.textTertiary,
          size: 27,
        );
      }),
    );

    // Translucent glass bar with softly rounded top corners. Content scrolls
    // behind it (extendBody) and shows faintly through the low-alpha fill;
    // a strong backdrop blur keeps the icons/labels legible.
    final radius = const BorderRadius.vertical(top: Radius.circular(24));
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          // Pull the icons/labels closer to the screen edge: keep only a small
          // slice of the safe-area inset instead of the full gesture-bar gap.
          padding: EdgeInsets.only(bottom: bottomInset * 0.5),
          decoration: BoxDecoration(
            // Lower alpha than surfaceCardGlass so content reads through it.
            color: TWColors.bgRaised.withValues(alpha: 0.40),
            borderRadius: radius,
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.06),
                width: 1,
              ),
            ),
          ),
          child: NavigationBarTheme(
            data: navTheme,
            child: NavigationBar(
              height: 60,
              backgroundColor: Colors.transparent,
              elevation: 0,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              destinations: destinations,
            ),
          ),
        ),
      ),
    );
  }
}
