import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// Raised when a social sign-in flow fails (not when the user cancels).
class SocialSignInException implements Exception {
  const SocialSignInException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Abstraction over the native Google / Apple sign-in flows.
///
/// Each method returns the provider **ID token** (a short-lived JWT) that the
/// app forwards to the TradeWizz backend for verification, or `null` when the
/// user cancels. The provider password and long-lived tokens are never handled
/// here — only the ID token leaves the device, and only the resulting TradeWizz
/// session is persisted by the caller.
abstract class SocialSignIn {
  /// True when the Apple button should be offered (iOS / macOS).
  bool get appleAvailable;

  /// True when the Google button should be offered (iOS + Android, and web).
  bool get googleAvailable;

  /// Returns a Google ID token, or null if cancelled.
  Future<String?> googleIdToken();

  /// Returns an Apple identity token, or null if cancelled.
  Future<String?> appleIdToken();
}

/// Default implementation backed by `google_sign_in` and `sign_in_with_apple`.
class PluginSocialSignIn implements SocialSignIn {
  PluginSocialSignIn();

  bool _googleInitialized = false;

  bool get _isApplePlatform {
    if (kIsWeb) return false;
    try {
      return Platform.isIOS || Platform.isMacOS;
    } catch (_) {
      return false;
    }
  }

  @override
  bool get appleAvailable => _isApplePlatform;

  @override
  bool get googleAvailable {
    if (kIsWeb) return true;
    try {
      return Platform.isIOS || Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> googleIdToken() async {
    try {
      final signIn = GoogleSignIn.instance;
      if (!_googleInitialized) {
        await signIn.initialize();
        _googleInitialized = true;
      }
      final account = await signIn.authenticate(scopeHint: const ['email']);
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const SocialSignInException(
          'Google did not return an ID token.',
        );
      }
      return idToken;
    } on GoogleSignInException catch (e) {
      // User cancelled -> treat as a no-op (null), surface real errors.
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      throw SocialSignInException('Google sign-in failed: ${e.description}');
    }
  }

  @override
  Future<String?> appleIdToken() async {
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final token = cred.identityToken;
      if (token == null || token.isEmpty) {
        throw const SocialSignInException(
          'Apple did not return an identity token.',
        );
      }
      return token;
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      throw SocialSignInException('Apple sign-in failed: ${e.message}');
    }
  }
}
