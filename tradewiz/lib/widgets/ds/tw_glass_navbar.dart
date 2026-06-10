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
          size: 24,
        );
      }),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        TWSpace.lg,
        0,
        TWSpace.lg,
        bottomInset > 0 ? bottomInset * 0.5 + TWSpace.sm : TWSpace.md,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(TWRadius.cardLg),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              color: TWColors.surfaceCardGlass,
              borderRadius: BorderRadius.circular(TWRadius.cardLg),
              border: Border.all(color: TWColors.hairlineTop, width: 1),
              boxShadow: TWShadow.ambient,
            ),
            child: NavigationBarTheme(
              data: navTheme,
              child: NavigationBar(
                height: 64,
                backgroundColor: Colors.transparent,
                elevation: 0,
                labelBehavior:
                    NavigationDestinationLabelBehavior.onlyShowSelected,
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                destinations: destinations,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
