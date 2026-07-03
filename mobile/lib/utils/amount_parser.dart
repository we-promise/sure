import 'package:intl/intl.dart';

class ParsedAmount {
  const ParsedAmount({
    required this.value,
    required this.canonicalValue,
    required this.displayText,
  });

  final double value;
  final String canonicalValue;
  final String displayText;
}

class AmountParser {
  static ParsedAmount parse(String input, {String? locale}) {
    final normalized = _normalizeMinus(input.trim());
    final negative = _isNegative(normalized);
    final numericText = normalized.replaceAll(RegExp(r'[^0-9.,]'), '');

    if (!RegExp(r'\d').hasMatch(numericText)) {
      throw const FormatException('Amount must contain digits');
    }

    final separators = _Separators.forLocale(locale);
    final decimalSeparator = _decimalSeparatorFor(numericText, separators);
    final canonical = _canonicalize(
      numericText,
      decimalSeparator: decimalSeparator,
      negative: negative,
    );

    return ParsedAmount(
      value: double.parse(canonical),
      canonicalValue: canonical,
      displayText: _displayText(normalized),
    );
  }

  static String canonicalize(String input, {String? locale}) {
    return parse(input, locale: locale).canonicalValue;
  }

  static String _normalizeMinus(String value) {
    return value
        .replaceAll('\u2212', '-')
        .replaceAll('\u2012', '-')
        .replaceAll('\u2013', '-')
        .replaceAll('\u2014', '-');
  }

  static bool _isNegative(String value) {
    final trimmed = value.trim();
    return trimmed.contains('-') ||
        (trimmed.startsWith('(') && trimmed.endsWith(')'));
  }

  static String _displayText(String value) {
    var display = value.trim();

    if (display.startsWith('(') && display.endsWith(')')) {
      display = display.substring(1, display.length - 1).trim();
    }

    display = display.replaceAll(RegExp(r'[-+]'), '').trim();

    return display;
  }

  static String _canonicalize(
    String numericText, {
    required String? decimalSeparator,
    required bool negative,
  }) {
    String integerDigits;
    String fractionDigits = '';

    if (decimalSeparator == null) {
      integerDigits = numericText.replaceAll(RegExp(r'\D'), '');
    } else {
      final decimalIndex = numericText.lastIndexOf(decimalSeparator);
      integerDigits =
          numericText.substring(0, decimalIndex).replaceAll(RegExp(r'\D'), '');
      fractionDigits =
          numericText.substring(decimalIndex + 1).replaceAll(RegExp(r'\D'), '');
    }

    integerDigits = integerDigits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (integerDigits.isEmpty) {
      integerDigits = '0';
    }

    fractionDigits = fractionDigits.replaceFirst(RegExp(r'0+$'), '');

    final unsigned = fractionDigits.isEmpty
        ? integerDigits
        : '$integerDigits.$fractionDigits';

    if (!negative || unsigned == '0') {
      return unsigned;
    }

    return '-$unsigned';
  }

  static String? _decimalSeparatorFor(
    String numericText,
    _Separators separators,
  ) {
    final lastDot = numericText.lastIndexOf('.');
    final lastComma = numericText.lastIndexOf(',');

    if (lastDot == -1 && lastComma == -1) {
      return null;
    }

    if (lastDot != -1 && lastComma != -1) {
      return lastDot > lastComma ? '.' : ',';
    }

    final separator = lastDot == -1 ? ',' : '.';
    final parts = numericText.split(separator);

    if (parts.length > 2) {
      if (_looksGrouped(parts)) {
        return null;
      }

      throw const FormatException('Invalid amount format');
    }

    if (separator == separators.decimalSeparator) {
      return separator;
    }

    final lastGroupLength = parts.last.length;
    if (separator == separators.groupSeparator && lastGroupLength == 3) {
      return null;
    }

    if (_looksGrouped(parts)) {
      return null;
    }

    return separator;
  }

  static bool _looksGrouped(List<String> parts) {
    if (parts.length < 2 || parts.first.isEmpty || parts.first.length > 3) {
      return false;
    }

    return parts.skip(1).every((part) => part.length == 3);
  }
}

class _Separators {
  const _Separators({
    required this.decimalSeparator,
    required this.groupSeparator,
  });

  final String decimalSeparator;
  final String groupSeparator;

  static _Separators forLocale(String? locale) {
    final effectiveLocale = locale ?? Intl.getCurrentLocale();

    try {
      final symbols = NumberFormat.decimalPattern(effectiveLocale).symbols;
      return _Separators(
        decimalSeparator: symbols.DECIMAL_SEP,
        groupSeparator: symbols.GROUP_SEP,
      );
    } catch (_) {
      if (_usesDecimalComma(effectiveLocale)) {
        return const _Separators(decimalSeparator: ',', groupSeparator: '.');
      }

      return const _Separators(decimalSeparator: '.', groupSeparator: ',');
    }
  }

  // Fallback heuristic for common decimal-comma locales when NumberFormat's
  // locale database cannot resolve the requested locale. Keep the set limited
  // to languages we intentionally support and extend it with tests as needed.
  static bool _usesDecimalComma(String locale) {
    final language = locale.split(RegExp(r'[-_]')).first.toLowerCase();
    return {
      'ca',
      'de',
      'es',
      'fr',
      'hu',
      'id',
      'it',
      'nl',
      'pl',
      'pt',
      'ro',
      'tr',
    }.contains(language);
  }
}
