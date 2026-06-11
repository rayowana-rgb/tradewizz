import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// TradeWizz "Wizard Terminal" design tokens.
///
/// Dark-first design language derived from the TradeWizz app icon:
/// a muted plum / grey-purple squircle, a glossy white-to-silver wizard hat,
/// an ascending white node chart, and dark-navy charcoal outlines.
/// Surfaces follow the icon's warm plum tone; the primary identity accent is
/// the icon's white/silver, with blue kept as a functional interactive accent.
/// View-layer only — adopt incrementally alongside the legacy [buildTradeWizTheme].
///
/// See: docs/design/TRADEWIZZ_UI_REDESIGN.md

// ---------------------------------------------------------------------------
// Color system
// ---------------------------------------------------------------------------
class TWColors {
  // Backgrounds — indigo-plum hybrid: the original deep indigo (#1B1830)
  // blended with the icon's warm plum (#3A3140 -> #4A3F52) so it keeps the
  // premium indigo depth while picking up the icon's warmth.
  static const Color bgBase = Color(0xFF1F1A2E); // indigo-plum, primary bg
  static const Color bgRaised = Color(0xFF2A2440); // secondary surface
  static const Color bgElevated = Color(0xFF362F4E); // elevated surface

  // Surfaces — lifted indigo-plum cards
  static const Color surfaceCard = Color(0xFF3D3556); // indigo-plum mid
  static const Color surfaceCardGlass = Color(0x8C3D3556); // 55% alpha

  // Identity accent — the icon's white / silver wizard + chart.
  static const Color wizardWhite = Color(0xFFFFFFFF);
  static const Color wizardSilver = Color(0xFFD0D0D5); // hat lowlight
  static const Color outlineNavy = Color(0xFF1E1B24); // icon charcoal outline

  // Functional interactive accent — vivid blue (original brand), pairs with
  // the white/silver wizard identity from the icon.
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

  // Lines — soft white hairlines + dark-navy charcoal edges (icon outlines)
  static const Color hairline = Color(0x14FFFFFF); // rgba(255,255,255,0.08)
  static const Color hairlineTop = Color(0x22FFFFFF); // 13% top sheen
  static const Color hairlineEdge = Color(0x4D1E1B24); // navy charcoal edge
  static const Color ringTrack = Color(0x14FFFFFF); // 8%
  static const Color sheetScrim = Color(0x8C120E1E); // 55% indigo-plum scrim

  // Gradients
  // Identity gradient: glossy white -> silver, like the wizard hat / chart.
  static const Gradient wizardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [wizardWhite, wizardSilver],
  );

  // Functional accent gradient (blue) for interactive CTAs.
  static const Gradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentBright, accent],
  );

  // Hero wash: warm plum top-left fading through indigo-plum to the deep
  // base — blends the icon's warmth with the original indigo depth.
  static const Gradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF453B52), bgElevated, bgBase],
  );

  // -- Premium surface (single source of truth: the Home "My Portfolio" card) --
  // Deep indigo -> dark violet -> electric blue. Signature TradeWizz surface.
  static const Color premiumIndigo = Color(0xFF2A2740);
  static const Color premiumViolet = Color(0xFF2E2C66);
  static const Gradient portfolioGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [premiumIndigo, premiumViolet, accent],
  );

  // Softer variant for dense content cards (metrics, news, reasoning) where the
  // electric-blue corner would distract. Same violet-indigo family, no blue.
  static const Gradient premiumGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF302B47), Color(0xFF2A2740)],
  );

  // Darker, near-flat indigo/navy surface for subtle informational cards
  // (e.g. Morning Brief). Recedes into the dark scene so the brighter
  // portfolio/premium gradient stays the signature focal surface.
  static const Gradient briefGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF221E36), Color(0xFF1C1930)],
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
  // Soft white halo for the wizard identity (orb / hero mark).
  static const List<BoxShadow> wizardGlow = [
    BoxShadow(color: Color(0x33FFFFFF), blurRadius: 30, offset: Offset(0, 0)),
  ];

  // Premium card depth: deep ambient drop + soft accent glow. This is the
  // exact shadow stack used by the Home "My Portfolio" card.
  static const List<BoxShadow> premium = [
    BoxShadow(color: Color(0x59000000), blurRadius: 32, offset: Offset(0, 12)),
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
  static const double card = 18;
  static const double cardLg = 22;
  static const double premium = 24; // premium surface (My Portfolio family)
  static const double button = 14;
  static const double sm = 10;
  static const double chip = 999;

  static BorderRadius get rCard => BorderRadius.circular(card);
  static BorderRadius get rCardLg => BorderRadius.circular(cardLg);
  static BorderRadius get rPremium => BorderRadius.circular(premium);
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
      fontSize: 28, height: 34 / 28, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: TWColors.textPrimary);
  static const TextStyle title1 = TextStyle(
      fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: TWColors.textPrimary);
  static const TextStyle title2 = TextStyle(
      fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w700, letterSpacing: -0.2, color: TWColors.textPrimary);
  static const TextStyle title3 = TextStyle(
      fontSize: 17, height: 22 / 17, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: TWColors.textPrimary);
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

  // No bundled font dependency: use the platform system font (SF Pro on iOS,
  // Roboto on Android). The rounded-geometric voice is approximated by weight
  // + tracking in TWType. Bundle 'Manrope' later if desired.
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
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
