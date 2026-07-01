/// Sure type scale.
///
/// Mirrors the Tailwind font-size defaults the web design system uses. Like
/// [SureSpacing], this is hand-authored rather than generated from
/// `design/tokens/sure.tokens.json` because the type scale comes from Tailwind's
/// built-in `text-*` ramp, not the canonical token file.
///
/// Font sizes are in logical pixels; use them instead of raw `fontSize` literals
/// so text stays on the scale. Each size has a paired line height
/// ([xsLineHeight] … [xxlLineHeight]), also in logical pixels, matching the
/// Tailwind `text-*` defaults. Flutter's `TextStyle.height` is a *multiplier*,
/// so derive it as `lineHeight / fontSize` when an exact pairing is needed, e.g.
/// `TextStyle(fontSize: SureTypography.sm, height: SureTypography.smLineHeight / SureTypography.sm)`.
class SureTypography {
  const SureTypography._();

  /// 12 / 16 — Tailwind `text-xs`.
  static const double xs = 12;

  /// 14 / 20 — Tailwind `text-sm`.
  static const double sm = 14;

  /// 16 / 24 — Tailwind `text-base`.
  static const double base = 16;

  /// 18 / 28 — Tailwind `text-lg`.
  static const double lg = 18;

  /// 20 / 28 — Tailwind `text-xl`.
  static const double xl = 20;

  /// 24 / 32 — Tailwind `text-2xl`.
  static const double xxl = 24;

  /// Line height (logical px) paired with [xs] — Tailwind `text-xs`.
  static const double xsLineHeight = 16;

  /// Line height (logical px) paired with [sm] — Tailwind `text-sm`.
  static const double smLineHeight = 20;

  /// Line height (logical px) paired with [base] — Tailwind `text-base`.
  static const double baseLineHeight = 24;

  /// Line height (logical px) paired with [lg] — Tailwind `text-lg`.
  static const double lgLineHeight = 28;

  /// Line height (logical px) paired with [xl] — Tailwind `text-xl`.
  static const double xlLineHeight = 28;

  /// Line height (logical px) paired with [xxl] — Tailwind `text-2xl`.
  static const double xxlLineHeight = 32;
}
