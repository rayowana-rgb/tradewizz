import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// TradeWizz "Wizard Terminal" design tokens.
///
/// Dark-first design language derived from the TradeWizz app icon
/// (muted violet squircle, glossy white wizard glyph, electric-blue signal).
/// View-layer only — adopt incrementally alongside the legacy [buildTradeWizTheme].
///
/// See: docs/design/TRADEWIZZ_UI_REDESIGN.md

// ---------------------------------------------------------------------------
// Color system
// ---------------------------------------------------------------------------
class TWColors {
  // Backgrounds
  static const Color bgBase = Color(0xFF1B1633);
  static const Color bgRaised = Color(0xFF221B3D);
  static const Color bgElevated = Color(0xFF2B2350);

  // Surfaces
  static const Color surfaceCard = Color(0xFF2F2858);
  static const Color surfaceCardGlass = Color(0x8C2F2858); // 55% alpha

  // Accent
  static const Color accent = Color(0xFF4F7CFF);
  static const Color accentBright = Color(0xFF6E8BFF);

  // Text
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFD6D8E7);
  static const Color textTertiary = Color(0xFFAEB3CC);

  // Semantic
  static const Color up = Color(0xFF3ED598);
  static const Color down = Color(0xFFFF6B81);
  static const Color warn = Color(0xFFFFC56F);
  static const Color neutral = Color(0xFFAEB3CC);
  static const Color info = Color(0xFF6E8BFF);

  static const Color upSoft = Color(0x243ED598); // ~14%
  static const Color downSoft = Color(0x24FF6B81);

  // Lines
  static const Color hairlineTop = Color(0x1AFFFFFF); // 10%
  static const Color hairlineEdge = Color(0x0FFFFFFF); // 6%
  static const Color ringTrack = Color(0x14FFFFFF); // 8%
  static const Color sheetScrim = Color(0x8C0A0816); // 55%

  // Gradients
  static const Gradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentBright, accent],
  );

  static const Gradient heroGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgElevated, bgBase],
  );

  /// Confidence ramp (0..100): down -> warn -> up.
  static Color confidence(num score) {
    if (score >= 70) return up;
    if (score >= 40) return warn;
    return down;
  }

  /// Signed change color.
  static Color delta(num change) => change >= 0 ? up : down;
}

// ---------------------------------------------------------------------------
// Shadows
// ---------------------------------------------------------------------------
class TWShadow {
  static const List<BoxShadow> ambient = [
    BoxShadow(color: Color(0x59000000), blurRadius: 32, offset: Offset(0, 12)),
  ];
  static const List<BoxShadow> ambientSm = [
    BoxShadow(color: Color(0x47000000), blurRadius: 18, offset: Offset(0, 6)),
  ];
  static const List<BoxShadow> accentGlow = [
    BoxShadow(color: Color(0x594F7CFF), blurRadius: 28, offset: Offset(0, 8)),
  ];
}

// ---------------------------------------------------------------------------
// Spacing (4-pt base, leaning large)
// ---------------------------------------------------------------------------
class TWSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;
  static const double xxxl = 40;
  static const double xxxxl = 56;
  static const double gutter = xl;
}

// ---------------------------------------------------------------------------
// Radius (brief: 20-28)
// ---------------------------------------------------------------------------
class TWRadius {
  static const double card = 24;
  static const double cardLg = 28;
  static const double button = 16;
  static const double sm = 12;
  static const double chip = 999;

  static BorderRadius get rCard => BorderRadius.circular(card);
  static BorderRadius get rCardLg => BorderRadius.circular(cardLg);
  static BorderRadius get rButton => BorderRadius.circular(button);
  static BorderRadius get rSm => BorderRadius.circular(sm);
  static BorderRadius get rChip => BorderRadius.circular(chip);
}

// ---------------------------------------------------------------------------
// Typography — rounded geometric sans, tabular numbers.
// Set `fontFamily` to 'Manrope' (bundled) or rely on SF Pro Rounded on iOS.
// ---------------------------------------------------------------------------
class TWType {
  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static const TextStyle display = TextStyle(
      fontSize: 34, height: 40 / 34, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: TWColors.textPrimary);
  static const TextStyle title1 = TextStyle(
      fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: TWColors.textPrimary);
  static const TextStyle title2 = TextStyle(
      fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: TWColors.textPrimary);
  static const TextStyle title3 = TextStyle(
      fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: TWColors.textPrimary);
  static const TextStyle body = TextStyle(
      fontSize: 16, height: 24 / 16, fontWeight: FontWeight.w500, color: TWColors.textSecondary);
  static const TextStyle bodySm = TextStyle(
      fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500, color: TWColors.textSecondary);
  static const TextStyle label = TextStyle(
      fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: TWColors.textPrimary);
  static const TextStyle caption = TextStyle(
      fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, letterSpacing: 0.2, color: TWColors.textTertiary);
  static const TextStyle overline = TextStyle(
      fontSize: 11, height: 14 / 11, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: TWColors.textTertiary);
  static const TextStyle monoNum = TextStyle(
      fontSize: 17, height: 22 / 17, fontWeight: FontWeight.w600, color: TWColors.textPrimary, fontFeatures: _tabular);

  /// Tabular variant of any style for prices/scores.
  static TextStyle tabular(TextStyle s) => s.copyWith(fontFeatures: _tabular);
}

// ---------------------------------------------------------------------------
// ThemeData — Material3 dark shell tuned to the design language.
// Keeps Material plumbing for compatibility while removing the Material "look".
// ---------------------------------------------------------------------------
ThemeData buildTradeWizzTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: TWColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    surface: TWColors.surfaceCard,
    primary: TWColors.accent,
    onPrimary: Colors.white,
    secondary: TWColors.accentBright,
    error: TWColors.down,
  );

  const fontFamily = 'Manrope'; // bundle in pubspec; falls back gracefully.

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: TWColors.bgBase,
    canvasColor: TWColors.bgBase,
    splashFactory: NoSplash.splashFactory, // no Material ripple
    highlightColor: Colors.transparent,
    dividerColor: TWColors.hairlineEdge,
    appBarTheme: const AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      foregroundColor: TWColors.textPrimary,
      titleTextStyle: TWType.title3,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: TWColors.surfaceCard,
      shape: RoundedRectangleBorder(borderRadius: TWRadius.rCard),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: TWColors.bgElevated,
      selectedColor: TWColors.accent,
      labelStyle: TWType.label,
      side: const BorderSide(color: TWColors.hairlineEdge),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: TWSpace.md, vertical: TWSpace.sm),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: _FadeUpTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    textTheme: const TextTheme(
      displayLarge: TWType.display,
      headlineLarge: TWType.title1,
      titleLarge: TWType.title2,
      titleMedium: TWType.title3,
      bodyLarge: TWType.body,
      bodyMedium: TWType.bodySm,
      labelLarge: TWType.label,
      bodySmall: TWType.caption,
      labelSmall: TWType.overline,
    ),
  );
}

/// Soft fade-through + slight rise page transition (320ms easeOutCubic).
class _FadeUpTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeUpTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.02), end: Offset.zero).animate(curved),
        child: child,
      ),
    );
  }
}
