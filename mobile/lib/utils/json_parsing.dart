class JsonParsing {
  static int? parseInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }

  static DateTime? parseDateTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static DateTime parseRequiredDateTime(dynamic value, String fieldName) {
    final parsed = parseDateTime(value);
    if (parsed == null) {
      throw FormatException('Invalid $fieldName date');
    }
    return parsed;
  }
}
