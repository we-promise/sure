class CustomProxyHeader {
  static final RegExp _headerNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  static const Set<String> _reservedNames = {
    'accept',
    'authorization',
    'content-type',
    'x-api-key',
  };

  final String name;
  final String value;

  CustomProxyHeader({
    required String name,
    required String value,
  })  : name = name.trim(),
        value = value.trim();

  factory CustomProxyHeader.fromJson(Map<String, dynamic> json) {
    return CustomProxyHeader(
      name: json['name'] as String? ?? '',
      value: json['value'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'value': value,
      };

  String get normalizedName => name.toLowerCase();

  String get redactedValue {
    if (value.isEmpty) return '';
    if (value.length <= 4) return '••••';
    return '••••••${value.substring(value.length - 4)}';
  }

  bool get isComplete => name.isNotEmpty && value.isNotEmpty;

  static String? validateName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 'Header name is required';
    if (!_headerNamePattern.hasMatch(trimmed)) {
      return 'Use a valid HTTP header name';
    }
    if (_reservedNames.contains(trimmed.toLowerCase())) {
      return 'This header is managed by the app';
    }
    return null;
  }

  static String? validateValue(String value) {
    if (value.trim().isEmpty) return 'Header value is required';
    return null;
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CustomProxyHeader &&
            name == other.name &&
            value == other.value;
  }

  @override
  int get hashCode => Object.hash(name, value);
}
