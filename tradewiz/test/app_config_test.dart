import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/config/app_config.dart';

void main() {
  // bool.fromEnvironment is resolved at COMPILE time, so what
  // AppConfig.fromEnvironment() reports depends on the --dart-define passed to
  // `flutter test`. We assert both the actual env-resolved value and the
  // explicit-constructor behavior (which the API client actually consumes).
  const fromEnv = bool.fromEnvironment(
    'TRADEWIZ_MOCK_FALLBACK',
    defaultValue: true,
  );

  test('fromEnvironment() reflects the TRADEWIZ_MOCK_FALLBACK define', () {
    final cfg = AppConfig.fromEnvironment();
    expect(cfg.mockFallback, fromEnv);
  });

  test('default mockFallback is true (no define)', () {
    // With no --dart-define, the compile-time default is true.
    if (const bool.hasEnvironment('TRADEWIZ_MOCK_FALLBACK') == false) {
      expect(AppConfig.fromEnvironment().mockFallback, isTrue);
    }
    // The constructor default is true regardless.
    const cfg = AppConfig(baseUrl: 'x');
    expect(cfg.mockFallback, isTrue);
  });

  test('mockFallback=false is respected by the config', () {
    const cfg = AppConfig(baseUrl: 'x', mockFallback: false);
    expect(cfg.mockFallback, isFalse);
  });

  test('TRADEWIZ_MOCK_FALLBACK=false disables fallback when defined', () {
    // Only meaningful when the suite is built with the define; otherwise the
    // value is the default (true) and this assertion is skipped.
    if (fromEnv == false) {
      expect(AppConfig.fromEnvironment().mockFallback, isFalse);
    } else {
      // Built without the false define: confirm default remains true.
      expect(AppConfig.fromEnvironment().mockFallback, isTrue);
    }
  });
}
