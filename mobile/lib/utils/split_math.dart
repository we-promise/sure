import 'package:intl/intl.dart';

import 'amount_parser.dart';

/// Why a split row amount was rejected.
enum SplitAmountError { required, invalid, zero, tooPrecise }

/// Exact decimal arithmetic for transaction splits.
///
/// The server stores amounts as `decimal(19,4)` and `split!` requires the
/// children to sum *exactly* to the parent, so floating point is not good
/// enough here (0.1 + 0.2 != 0.3). Amounts are held as [BigInt] counts of
/// 1/10^[scale] units instead.
class SplitMath {
  const SplitMath._();

  /// Matches the API's `AMOUNT_SCALE` (`entries.amount` is decimal(19,4)).
  static const int scale = 4;

  static final BigInt _unit = BigInt.from(10).pow(scale);

  /// Number of minor-unit digits for [currency] (2 for USD/EUR, 0 for JPY,
  /// 3 for KWD), falling back to 2 for unknown codes.
  static int currencyDecimals(String currency) {
    if (currency.trim().isEmpty) return 2;
    try {
      return NumberFormat.currency(name: currency.toUpperCase())
              .decimalDigits ??
          2;
    } catch (_) {
      return 2;
    }
  }

  /// Parses a plain decimal string (`"12.5"`, `"-0.3333"`, `"1.5e2"`) into
  /// scaled units. Returns null when [input] is not a number or carries more
  /// than [scale] significant decimal places.
  static BigInt? parseUnits(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;

    var exponent = 0;
    final expMatch = RegExp(r'^(.*?)[eE]([+-]?\d+)$').firstMatch(text);
    if (expMatch != null) {
      text = expMatch.group(1)!;
      exponent = int.parse(expMatch.group(2)!);
    }

    final match = RegExp(r'^([+-])?(\d*)(?:\.(\d*))?$').firstMatch(text);
    if (match == null) return null;

    final negative = match.group(1) == '-';
    final intPart = match.group(2) ?? '';
    var fracPart = match.group(3) ?? '';
    if (intPart.isEmpty && fracPart.isEmpty) return null;

    var digits = '$intPart$fracPart';
    var decimals = fracPart.length - exponent;
    if (decimals < 0) {
      digits = digits + '0' * -decimals;
      decimals = 0;
    }

    // Drop trailing zeros beyond the supported scale ("1.50000" is fine).
    while (decimals > scale && digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
      decimals--;
    }
    if (decimals > scale) return null;

    digits = digits + '0' * (scale - decimals);
    final value = BigInt.parse(digits.isEmpty ? '0' : digits);
    return negative ? -value : value;
  }

  /// Parses user input typed in the app's locale (e.g. `"1 234,56"` in
  /// Swedish) into scaled units. Locale separator handling is delegated to
  /// [AmountParser]; input with anything but digits, separators, spaces and
  /// a sign is rejected (AmountParser alone would silently drop letters).
  /// Returns null when the input is not a plain number.
  static BigInt? parseUserInput(String input, {String? locale}) {
    final text = input.trim();
    if (text.isEmpty) return null;
    if (RegExp(r'[^0-9.,+\-\u2212\u2012\u2013\u2014\s\u00A0\u202F]')
        .hasMatch(text)) {
      return null;
    }
    try {
      final canonical = AmountParser.canonicalize(text, locale: locale);
      if (!RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)$').hasMatch(canonical)) {
        return null;
      }
      return parseUnits(canonical);
    } on FormatException {
      return null;
    }
  }

  /// Number of decimal places actually used by [units] (0..[scale]).
  static int decimalsUsed(BigInt units) {
    var abs = units.abs();
    var used = scale;
    final ten = BigInt.from(10);
    while (used > 0 && abs % ten == BigInt.zero) {
      abs = abs ~/ ten;
      used--;
    }
    return used;
  }

  /// Decimal places a split row may use: the currency's precision, widened
  /// only when the stored parent amount itself carries finer precision (so
  /// the rows can still add up to it exactly).
  static int inputDecimals(String currency, BigInt parentUnits) {
    final currencyDigits = currencyDecimals(currency);
    final parentDigits = decimalsUsed(parentUnits);
    final digits =
        parentDigits > currencyDigits ? parentDigits : currencyDigits;
    return digits > scale ? scale : digits;
  }

  /// Whether [units] can be expressed with [decimals] decimal places.
  static bool fitsDecimals(BigInt units, int decimals) {
    if (decimals >= scale) return true;
    final step = BigInt.from(10).pow(scale - decimals);
    return units % step == BigInt.zero;
  }

  /// Formats scaled units as a plain decimal string with exactly [decimals]
  /// places (or more, if needed to stay exact). Suitable for the API.
  static String toDecimalString(BigInt units, {int? decimals}) {
    final negative = units.isNegative;
    final abs = units.abs();
    final whole = abs ~/ _unit;
    var frac = (abs % _unit).toString().padLeft(scale, '0');

    var keep = decimals ?? scale;
    final needed = decimalsUsed(abs);
    if (needed > keep) keep = needed;
    frac = frac.substring(0, keep);

    final body = keep == 0 ? '$whole' : '$whole.$frac';
    return negative && abs != BigInt.zero ? '-$body' : body;
  }

  /// Converts scaled units to a double for display formatting only.
  static double toDouble(BigInt units) => units.toDouble() / _unit.toDouble();

  /// Formats [units] as money in [currency] using [decimals] places.
  static String formatMoney(
    BigInt units,
    String currency, {
    required int decimals,
    String? locale,
  }) {
    try {
      return NumberFormat.simpleCurrency(
        locale: locale,
        name: currency.isEmpty ? null : currency.toUpperCase(),
        decimalDigits: decimals,
      ).format(toDouble(units));
    } catch (_) {
      final text = toDecimalString(units, decimals: decimals);
      return currency.isEmpty ? text : '$text $currency';
    }
  }

  /// Validates one row's typed amount. Returns null when it is acceptable.
  static SplitAmountError? validateAmount(
    String input, {
    required int decimals,
    String? locale,
  }) {
    if (input.trim().isEmpty) return SplitAmountError.required;
    final units = parseUserInput(input, locale: locale);
    if (units == null) {
      // More than [scale] places parses as null too; report it as precision.
      final widened = RegExp(r'^[+-]?\d*[.,]\d{5,}$').hasMatch(input.trim());
      return widened ? SplitAmountError.tooPrecise : SplitAmountError.invalid;
    }
    if (units == BigInt.zero) return SplitAmountError.zero;
    if (!fitsDecimals(units, decimals)) return SplitAmountError.tooPrecise;
    return null;
  }

  /// What is left to allocate: [total] minus every parseable row amount.
  static BigInt remaining(
    BigInt total,
    Iterable<String> rowInputs, {
    String? locale,
  }) {
    var sum = BigInt.zero;
    for (final input in rowInputs) {
      sum += parseUserInput(input, locale: locale) ?? BigInt.zero;
    }
    return total - sum;
  }
}
