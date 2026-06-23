import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the private Moomoo bridge shared secret (the `X-Moomoo-Secret`
/// header value) in the platform secure store (iOS Keychain / Android
/// EncryptedSharedPreferences).
///
/// This is intentionally NOT embedded in the app binary: the owner enters it
/// once on-device. Without it, live trading is unavailable (the backend
/// returns 503/403). It is never logged.
abstract class MoomooSecretPersistence {
  Future<String?> read();
  Future<void> write(String secret);
  Future<void> clear();
}

class SecureMoomooSecretPersistence implements MoomooSecretPersistence {
  SecureMoomooSecretPersistence([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'tradewizz.moomoo.secret';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String secret) =>
      _storage.write(key: _key, value: secret);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// In-memory cache around the persistence so the UI can read synchronously
/// after a one-time load. A [ChangeNotifier] so screens react to set/clear.
class MoomooSecretStore extends ChangeNotifier {
  MoomooSecretStore({MoomooSecretPersistence? persistence})
      : _persistence = persistence ?? SecureMoomooSecretPersistence();

  final MoomooSecretPersistence _persistence;

  String? _secret;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  bool get hasSecret => (_secret != null && _secret!.isNotEmpty);
  String? get secret => _secret;

  Future<void> load() async {
    if (_loaded) return;
    try {
      _secret = await _persistence.read();
    } catch (_) {
      _secret = null;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setSecret(String secret) async {
    final s = secret.trim();
    _secret = s.isEmpty ? null : s;
    notifyListeners();
    if (_secret == null) {
      await _persistence.clear();
    } else {
      await _persistence.write(_secret!);
    }
  }

  Future<void> clear() async {
    _secret = null;
    notifyListeners();
    await _persistence.clear();
  }
}
