import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/sure_colors.dart';

/// The Sure wordmark logomark.
///
/// The wordmark's muted strokes are `currentColor` in the asset; this widget
/// tints them with the theme's secondary text color so the mark stays legible in
/// both light and dark (a hardcoded grey was too dim on the dark surface), while
/// the green brand mark keeps its own fill. Use this everywhere the logomark is
/// shown so no caller renders the `currentColor` strokes as the flutter_svg
/// default (black).
class SureLogo extends StatelessWidget {
  const SureLogo({super.key, this.size = 36});

  /// Square edge length in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/images/logomark.svg',
      width: size,
      height: size,
      theme: SvgTheme(
        currentColor: SureColors.of(context).palette.textSecondary,
      ),
    );
  }
}
