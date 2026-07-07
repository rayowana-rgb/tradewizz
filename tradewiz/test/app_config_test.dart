import 'package:flutter_test/flutter_test.dart';

import 'package:tradewiz/config/app_config.dart';

void main() {
  // bool.fromEnvironment is resolved at COMPILE time, so what
  // AppConfig.fromEnvironment() reports depends on the --dart-define passed to
  // `flutter test`. We assert both the actual env-resolved value and the
  // explicit-constructor behavior (which the API client actually consumes).
  const fromEnv = bool.fromEnvironment(
    'TRADEWIZ_MOCK_FALLBACK',
    defaultValue: false,
  );

  test('fromEnvironment() reflects the TRADEWIZ_MOCK_FALLBACK define', () {
    final cfg = AppConfig.fromEnvironment();
    expect(cfg.mockFallback, fromEnv);
  });

  test('env default mockFallback is false (honesty over mock data)', () {
    // With no --dart-define, the compile-time env default is now false so the
    // shipped app surfaces "backend unreachable" instead of Sample data.
    if (const bool.hasEnvironment('TRADEWIZ_MOCK_FALLBACK') == false) {
      expect(AppConfig.fromEnvironment().mockFallback, isFalse);
    }
  });

  test('constructor default mockFallback is true (test convenience)', () {
    // The bare constructor default stays true so widget tests keep working
    // offline without every call site opting in.
    const cfg = AppConfig(baseUrl: 'x');
    expect(cfg.mockFallback, isTrue);
  });

  test('mockFallback=false is respected by the config', () {
    const cfg = AppConfig(baseUrl: 'x', mockFallback: false);
    expect(cfg.mockFallback, isFalse);
  });

  test('TRADEWIZ_MOCK_FALLBACK=true re-enables fallback when defined', () {
    // Only meaningful when the suite is built with the define; otherwise the
    // value is the env default (false) and this asserts that instead.
    if (fromEnv == true) {
      expect(AppConfig.fromEnvironment().mockFallback, isTrue);
    } else {
      expect(AppConfig.fromEnvironment().mockFallback, isFalse);
    }
  });
}
