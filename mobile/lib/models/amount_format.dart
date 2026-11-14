/// Number formatting rules resolved by the server.
///
/// Mirrors `Money::DisplayFormat` on the API. Clients render amounts with
/// these rules rather than inferring grouping from their own locale.
class AmountFormat {
  static const String _fallbackKey = 'language';
  static const String _fallbackGrouping = 'standard';
  static const String _fallbackDelimiter = ',';
  static const String _fallbackSeparator = '.';
  static const String _fallbackSymbolPosition = 'before';
  static const String _fallbackSymbolSpacing = '';

  static const Set<String> _validKeys = {
    'language',
    'international',
    'indian',
    'european',
  };
  static const Set<String> _validGroupings = {'standard', 'indian'};
  static const Set<String> _validDelimiters = {',', '.', ' ', '\u00A0'};
  static const Set<String> _validSeparators = {',', '.'};
  static const Set<String> _validSymbolPositions = {'before', 'after'};
  static const Set<String> _validSymbolSpacings = {'', ' ', '\u00A0'};

  final String key;
  final String grouping;
  final String delimiter;
  final String separator;
  final String symbolPosition;
  final String symbolSpacing;

  const AmountFormat({
    this.key = _fallbackKey,
    this.grouping = _fallbackGrouping,
    this.delimiter = _fallbackDelimiter,
    this.separator = _fallbackSeparator,
    this.symbolPosition = _fallbackSymbolPosition,
    this.symbolSpacing = _fallbackSymbolSpacing,
  });

  /// Missing or malformed values fall back to International rules, so older
  /// servers and partial payloads never crash the app.
  factory AmountFormat.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) {
      return const AmountFormat();
    }

    String read(String snake, String camel) {
      final value = json[snake] ?? json[camel];
      return value is String ? value : '';
    }

    final key = _validKeys.contains(read('key', 'key'))
        ? read('key', 'key')
        : _fallbackKey;
    final grouping = _validGroupings.contains(read('grouping', 'grouping'))
        ? read('grouping', 'grouping')
        : _fallbackGrouping;
    final delimiter = _validDelimiters.contains(read('delimiter', 'delimiter'))
        ? read('delimiter', 'delimiter')
        : _fallbackDelimiter;
    final separator = _validSeparators.contains(read('separator', 'separator'))
        ? read('separator', 'separator')
        : _fallbackSeparator;
    final symbolPosition = _validSymbolPositions
            .contains(read('symbol_position', 'symbolPosition'))
        ? read('symbol_position', 'symbolPosition')
        : _fallbackSymbolPosition;
    final symbolSpacing =
        _validSymbolSpacings.contains(read('symbol_spacing', 'symbolSpacing'))
            ? read('symbol_spacing', 'symbolSpacing')
            : _fallbackSymbolSpacing;

    return AmountFormat(
      key: key,
      grouping: grouping,
      delimiter: delimiter,
      separator: separator,
      symbolPosition: symbolPosition,
      symbolSpacing: symbolSpacing,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'grouping': grouping,
      'delimiter': delimiter,
      'separator': separator,
      'symbol_position': symbolPosition,
      'symbol_spacing': symbolSpacing,
    };
  }

  AmountFormat copyWith({
    String? key,
    String? grouping,
    String? delimiter,
    String? separator,
    String? symbolPosition,
    String? symbolSpacing,
  }) {
    return AmountFormat(
      key: key ?? this.key,
      grouping: grouping ?? this.grouping,
      delimiter: delimiter ?? this.delimiter,
      separator: separator ?? this.separator,
      symbolPosition: symbolPosition ?? this.symbolPosition,
      symbolSpacing: symbolSpacing ?? this.symbolSpacing,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AmountFormat &&
        other.key == key &&
        other.grouping == grouping &&
        other.delimiter == delimiter &&
        other.separator == separator &&
        other.symbolPosition == symbolPosition &&
        other.symbolSpacing == symbolSpacing;
  }

  @override
  int get hashCode => Object.hash(
        key,
        grouping,
        delimiter,
        separator,
        symbolPosition,
        symbolSpacing,
      );
}
