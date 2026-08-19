/// Sure spacing scale.
///
/// Mirrors the Tailwind spacing defaults the web design system relies on
/// (`1rem = 16px`, so each step is `value * 4px`). Hand-authored rather than
/// generated from `design/tokens/sure.tokens.json` because spacing is not part
/// of the canonical token file — it comes from Tailwind's built-in scale, which
/// is stable and shared across the web and mobile apps.
///
/// Use these instead of raw numeric `EdgeInsets`/`SizedBox` values so padding
/// and gaps stay on the scale. Component-specific dimensions (control heights,
/// hairline dividers) intentionally stay as literals — they are sizing, not
/// spacing-scale steps.
class SureSpacing {
  const SureSpacing._();

  /// 4 — Tailwind `space-1`.
  static const double xs = 4;

  /// 6 — Tailwind `space-1.5`.
  static const double sm = 6;

  /// 8 — Tailwind `space-2`.
  static const double md = 8;

  /// 12 — Tailwind `space-3`.
  static const double lg = 12;

  /// 16 — Tailwind `space-4`.
  static const double xl = 16;

  /// 20 — Tailwind `space-5`.
  static const double xxl = 20;

  /// 24 — Tailwind `space-6`.
  static const double xxxl = 24;

  /// 32 — Tailwind `space-8`.
  static const double huge = 32;
}
