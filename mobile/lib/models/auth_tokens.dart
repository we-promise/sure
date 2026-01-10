class AuthTokens {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;
  final int createdAt;

  AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
    required this.expiresIn,
    required this.createdAt,
  });

  factory AuthTokens.fromJson(Map<String, dynamic> json) {
    return AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      tokenType: json['token_type'] as String,
      expiresIn: _parseToInt(json['expires_in']),
      createdAt: _parseToInt(json['created_at']),
    );
  }

  /// Helper method to parse a value to int, handling both String and int types
  static int _parseToInt(dynamic value) {
    if (value is int) {
      return value;
    } else if (value is String) {
      return int.parse(value);
    } else {
      throw FormatException('Cannot parse $value to int');
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'token_type': tokenType,
      'expires_in': expiresIn,
      'created_at': createdAt,
    };
  }

  bool get isExpired {
    final expirationTime = DateTime.fromMillisecondsSinceEpoch(
      (createdAt + expiresIn) * 1000,
    );
    return DateTime.now().isAfter(expirationTime);
  }
}
