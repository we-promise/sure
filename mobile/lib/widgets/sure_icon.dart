import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Sure design-system icon primitive.
///
/// Renders a bundled Lucide SVG (stroke `currentColor`, 2px) tinted to a single
/// color, mirroring the web `icon` helper / `DS::FilledIcon` semantics: tokenized
/// size, color inherited from the surrounding [IconTheme] by default, and
/// accessibility that distinguishes decorative from meaningful icons.
///
/// Use [SureIcons] for the bundled icon names so call sites stay typo-safe and
/// only reference assets that actually ship in `assets/icons/lucide/`.
///
/// ```dart
/// const SureIcon(SureIcons.wallet, size: SureIconSize.lg)            // decorative
/// const SureIcon(SureIcons.refresh, semanticLabel: 'Refresh')        // meaningful
/// ```
class SureIcon extends StatelessWidget {
  /// Lucide icon name (kebab-case), e.g. `wallet`. Prefer [SureIcons] constants.
  final String name;

  /// Square edge length in logical pixels. Prefer a [SureIconSize] token. When
  /// null, inherits the ambient [IconTheme] size (Material-icon parity), falling
  /// back to 24 — so dropping `SureIcon` in for `Icon` preserves sizing.
  final double? size;

  /// Tint applied to the icon. When null, inherits the ambient [IconTheme]
  /// color (Material-icon parity), falling back to opaque black only if unset.
  final Color? color;

  /// When provided, the icon is exposed to assistive tech with this label
  /// (meaningful icon). When null, the icon is decorative and excluded from the
  /// semantics tree — use this only when an adjacent widget carries the name.
  final String? semanticLabel;

  const SureIcon(
    this.name, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color ?? const Color(0xFF000000);
    // Mirror Material `Icon`: always paint the glyph at `resolvedSize`, even when
    // a parent imposes tight constraints larger than the icon (e.g. a fixed-size
    // Container). The outer SizedBox sets the intrinsic size; the Center loosens
    // the constraints handed to SvgPicture so its width/height aren't stretched.
    return SizedBox(
      width: resolvedSize,
      height: resolvedSize,
      child: Center(
        child: SvgPicture.asset(
          'assets/icons/lucide/$name.svg',
          width: resolvedSize,
          height: resolvedSize,
          colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
          semanticsLabel: semanticLabel,
          excludeFromSemantics: semanticLabel == null,
        ),
      ),
    );
  }
}

/// Canonical icon sizes, mirroring the web `icon` helper scale
/// (xs/sm/md/lg/xl/2xl → 12/16/20/24/28/32).
abstract final class SureIconSize {
  static const double xs = 12;
  static const double sm = 16;
  static const double md = 20;
  static const double lg = 24;
  static const double xl = 28;
  static const double xxl = 32;
}

/// Names of the Lucide icons bundled under `assets/icons/lucide/`.
///
/// Referencing a name here guarantees the asset ships; add the SVG (and a
/// constant) before using a new icon.
abstract final class SureIcons {
  static const String landmark = 'landmark';
  static const String creditCard = 'credit-card';
  static const String trendingUp = 'trending-up';
  static const String trendingDown = 'trending-down';
  static const String receipt = 'receipt';
  static const String house = 'house';
  static const String car = 'car';
  static const String bitcoin = 'bitcoin';
  static const String shapes = 'shapes';
  static const String handCoins = 'hand-coins';
  static const String wallet = 'wallet';
  static const String circleAlert = 'circle-alert';
  static const String circleCheck = 'circle-check';
  static const String cloudCheck = 'cloud-check';
  static const String refresh = 'refresh-cw';
  static const String chevronUp = 'chevron-up';
  static const String chevronDown = 'chevron-down';
  static const String chevronRight = 'chevron-right';
}
