class User {
  final String id;
  final String email;
  final String? firstName;
  final String? lastName;
  final String uiLayout;
  final bool aiEnabled;

  User({
    required this.id,
    required this.email,
    this.firstName,
    this.lastName,
    required this.uiLayout,
    required this.aiEnabled,
  });

  bool get isIntroLayout => uiLayout == 'intro';

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'].toString(),
      email: json['email'] as String,
      firstName: json['first_name'] as String?,
      lastName: json['last_name'] as String?,
      uiLayout: (json['ui_layout'] as String?) ?? 'dashboard',
      // Default to true when key is absent (legacy payloads from older app versions).
      // Avoids regressing existing users who would otherwise be incorrectly gated.
      aiEnabled: json.containsKey('ai_enabled')
          ? (json['ai_enabled'] == true)
          : true,
    );
  }

  User copyWith({
    String? id,
    String? email,
    String? firstName,
    String? lastName,
    String? uiLayout,
    bool? aiEnabled,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      uiLayout: uiLayout ?? this.uiLayout,
      aiEnabled: aiEnabled ?? this.aiEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'first_name': firstName,
      'last_name': lastName,
      'ui_layout': uiLayout,
      'ai_enabled': aiEnabled,
    };
  }

  String get displayName {
    if (firstName != null && lastName != null) {
      return '$firstName $lastName';
    }
    if (firstName != null) {
      return firstName!;
    }
    return email;
  }
}
