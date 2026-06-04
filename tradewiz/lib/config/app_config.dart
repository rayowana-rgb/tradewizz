/// App-wide configuration, overridable at build time via --dart-define.
///
/// Example:
///   flutter run --dart-define=TRADEWIZ_API_BASE_URL=https://staging.tradewiz.app/v1
class AppConfig {
  const AppConfig({
    required this.baseUrl,
    this.requestTimeout = const Duration(seconds: 10),
    this.mockFallback = true,
  });

  final String baseUrl;
  final Duration requestTimeout;

  /// When true, network failures fall back to mocked data so the app stays
  /// usable while the backend is offline or unreachable.
  final bool mockFallback;

  static const String _baseUrlFromEnv = String.fromEnvironment(
    'TRADEWIZ_API_BASE_URL',
    defaultValue: 'https://api.tradewiz.app/v1',
  );

  /// Config resolved from --dart-define values (with sensible defaults).
  factory AppConfig.fromEnvironment() {
    return const AppConfig(baseUrl: _baseUrlFromEnv);
  }
}
