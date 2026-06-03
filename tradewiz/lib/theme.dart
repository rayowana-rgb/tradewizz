import 'package:flutter/material.dart';

/// Central, clean theme for TradeWiz.
class AppColors {
  static const Color seed = Color(0xFF1E88E5);
  static const Color up = Color(0xFF1DB954);
  static const Color down = Color(0xFFE53935);
}

ThemeData buildTradeWizTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFFF7F8FA),
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: Color(0xFF1A1C1E),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
  );
}
