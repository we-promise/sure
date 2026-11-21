import '../models/amount_format.dart';

/// Formats amounts using the rules the server resolved for the signed-in user.
///
/// The app never infers grouping from its own locale or country: the server
/// sends the exact grouping style, delimiters and symbol placement so web,
/// API and mobile agree.
class MoneyFormatter {
  /// Numeric portion only, honoring [format]'s grouping and separators.
  ///
  /// Rounds to [maxFractionDigits], pads to at least [minFractionDigits], and
  /// trims trailing zeros unless [keepTrailingZeros] is true.
  static String decimal(
    num value,
    AmountFormat format, {
    int maxFractionDigits = 2,
    int minFractionDigits = 0,
    bool keepTrailingZeros = false,
  }) {
    final rounded = value.toStringAsFixed(maxFractionDigits.clamp(0, 20));
    final isNegative = rounded.startsWith('-');
    final body = isNegative ? rounded.substring(1) : rounded;

    final separatorIndex = body.indexOf('.');
    final integerDigits =
        separatorIndex == -1 ? body : body.substring(0, separatorIndex);
    var fractionDigits =
        separatorIndex == -1 ? '' : body.substring(separatorIndex + 1);

    if (!keepTrailingZeros) {
      fractionDigits = fractionDigits.replaceFirst(RegExp(r'0+$'), '');
    }
    if (fractionDigits.length < minFractionDigits) {
      fractionDigits = fractionDigits.padRight(minFractionDigits, '0');
    }

    final grouped = _group(integerDigits, format);
    final result = fractionDigits.isEmpty
        ? grouped
        : '$grouped${format.separator}$fractionDigits';

    return isNegative ? '-$result' : result;
  }

  /// Numeric portion prefixed or suffixed with [symbol] according to the
  /// server's symbol position and spacing.
  static String currency(
    num value,
    AmountFormat format, {
    required String symbol,
    int maxFractionDigits = 2,
    int minFractionDigits = 0,
    bool keepTrailingZeros = false,
  }) {
    final number = decimal(
      value,
      format,
      maxFractionDigits: maxFractionDigits,
      minFractionDigits: minFractionDigits,
      keepTrailingZeros: keepTrailingZeros,
    );

    if (format.symbolPosition == 'after') {
      return '$number${format.symbolSpacing}$symbol';
    }

    final isNegative = number.startsWith('-');
    final magnitude = isNegative ? number.substring(1) : number;
    final formatted = '$symbol${format.symbolSpacing}$magnitude';

    return isNegative ? '-$formatted' : formatted;
  }

  static String _group(String digits, AmountFormat format) {
    if (format.grouping == 'indian') {
      return _groupIndian(digits, format.delimiter);
    }
    return _groupStandard(digits, format.delimiter);
  }

  static String _groupStandard(String digits, String delimiter) {
    if (digits.length <= 3) return digits;

    final buffer = StringBuffer();
    final firstGroupLength = digits.length % 3;
    var index = 0;

    if (firstGroupLength > 0) {
      buffer.write(digits.substring(0, firstGroupLength));
      index = firstGroupLength;
    }

    while (index < digits.length) {
      if (buffer.isNotEmpty) buffer.write(delimiter);
      buffer.write(digits.substring(index, index + 3));
      index += 3;
    }

    return buffer.toString();
  }

  static String _groupIndian(String digits, String delimiter) {
    if (digits.length <= 3) return digits;

    final lastThree = digits.substring(digits.length - 3);
    var rest = digits.substring(0, digits.length - 3);
    final groups = <String>[];

    while (rest.length > 2) {
      groups.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) groups.insert(0, rest);

    return '${groups.join(delimiter)}$delimiter$lastThree';
  }
}
