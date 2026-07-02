/// Sure type scale.
///
/// Mirrors the Tailwind font-size defaults the web design system uses. Like
/// [SureSpacing], this is hand-authored rather than generated from
/// `design/tokens/sure.tokens.json` because the type scale comes from Tailwind's
/// built-in `text-*` ramp, not the canonical token file.
///
/// Values are font sizes in logical pixels; the comment on each records the
/// Tailwind step and its paired line-height for reference. Use these instead of
/// raw `fontSize` literals so text stays on the scale.
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
}
