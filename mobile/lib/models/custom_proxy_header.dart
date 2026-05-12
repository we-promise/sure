class CustomProxyHeader {
  static final RegExp _headerNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
  // Reject ASCII control bytes in values to block CR/LF header injection.
  static final RegExp _headerValueControlChars = RegExp(r'[\x00-\x1F\x7F]');
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

  // Length is intentionally obscured: short values get a fixed 4-bullet mask
  // and longer values get a fixed 6-bullet prefix + last 4 chars. Keeping the
  // last 4 lets users sanity-check what they entered without leaking length.
  String get redactedValue {
    if (value.isEmpty) return '';
    if (value.length <= 4) return '••••';
    return '••••••${value.substring(value.length - 4)}';
  }

  /// Drops headers with empty/invalid name or value, then dedupes by
  /// case-insensitive name (last write wins). Single source of truth used by
  /// both `ApiConfig.setCustomProxyHeaders` and the persistence service.
  static List<CustomProxyHeader> sanitize(List<CustomProxyHeader> headers) {
    final byName = <String, CustomProxyHeader>{};
    for (final header in headers) {
      if (!header.isComplete) continue;
      if (validateName(header.name) != null) continue;
      if (validateValue(header.value) != null) continue;
      byName[header.normalizedName] = header;
    }
    return byName.values.toList(growable: false);
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
    if (_headerValueControlChars.hasMatch(value)) {
      return 'Header value contains control characters';
    }
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
