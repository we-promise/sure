/// Masks monetary values for "privacy mode", where the user wants amounts
/// hidden from over-the-shoulder view.
///
/// The numeric portion of an amount (its digits and any embedded grouping/
/// decimal separators) is collapsed into a short, fixed run of bullets, while
/// the currency symbol/code and sign are kept. So `CA$1,234.56` -> `CA$••••`
/// and `-$42,078.35` -> `-$••••`. A fixed run (rather than one bullet per
/// digit) avoids leaking the value's magnitude and reads cleanly without stray
/// separators. Non-numeric characters are untouched, so the masker is currency-
/// and locale-agnostic — it works on any already-formatted amount string.
class MoneyMasker {
  const MoneyMasker._();

  /// The character used to mask digits.
  static const String maskChar = '•'; // •

  /// The fixed run of [maskChar] that replaces the numeric portion of an amount.
  static const String maskedNumber = '$maskChar$maskChar$maskChar$maskChar';

  /// A maximal run of digits and the separators embedded within them, requiring
  /// at least one digit so symbol-only strings (e.g. the `--` placeholder) are
  /// left alone.
  static final RegExp _numericRun = RegExp(r'[\d.,]*\d[\d.,]*');

  /// Returns [formatted] with its numeric portion replaced by [maskedNumber],
  /// preserving the currency symbol/code and sign. If [hidden] is false,
  /// [formatted] is returned unchanged.
  static String mask(String formatted, {bool hidden = true}) {
    if (!hidden) return formatted;
    return formatted.replaceAll(_numericRun, maskedNumber);
  }
}
