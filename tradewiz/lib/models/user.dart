/// Authenticated user profile (from /v1/auth/me, /register, /login).
class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.createdAt,
    required this.updatedAt,
    this.connectedBrokers = 0,
    this.provider = 'EMAIL',
  });

  final int id;
  final String email;
  final String createdAt;
  final String updatedAt;
  final int connectedBrokers;

  /// Auth provider: 'EMAIL', 'GOOGLE' or 'APPLE'.
  final String provider;

  factory UserProfile.fromJson(Map<String, dynamic> j) => UserProfile(
        id: (j['id'] as num?)?.toInt() ?? 0,
        email: j['email'] as String? ?? '',
        createdAt: j['created_at'] as String? ?? '',
        updatedAt: j['updated_at'] as String? ?? '',
        connectedBrokers: (j['connected_brokers'] as num?)?.toInt() ?? 0,
        provider: j['provider'] as String? ?? 'EMAIL',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'connected_brokers': connectedBrokers,
        'provider': provider,
      };
}

/// Result of register/login: access token + user.
class AuthResult {
  const AuthResult({required this.accessToken, required this.user});

  final String accessToken;
  final UserProfile user;

  factory AuthResult.fromJson(Map<String, dynamic> j) => AuthResult(
        accessToken: j['access_token'] as String? ?? '',
        user: UserProfile.fromJson(
            (j['user'] as Map<String, dynamic>?) ?? const {}),
      );
}
