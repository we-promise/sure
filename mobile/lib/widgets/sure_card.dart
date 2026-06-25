import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';

/// Sure design-system card — a tokenized content surface mirroring the web card
/// chrome (`bg-container` + a hairline border + rounded corners + the subtle DS
/// shadow). Use it instead of a Material [Card] so the chrome stays in lockstep
/// with `sure.tokens.json` and reads correctly in light and dark.
///
/// Colors resolve from the active [SureColors] palette (brightness-aware). When
/// [onTap] is provided the whole card is tappable, with a flat ink response
/// clipped to the card's radius.
class SureCard extends StatelessWidget {
  const SureCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.elevated = true,
  });

  final Widget child;

  /// Inner padding around [child].
  final EdgeInsetsGeometry padding;

  /// Outer spacing around the card (e.g. separation in a list).
  final EdgeInsetsGeometry? margin;

  /// When non-null, the card is tappable.
  final VoidCallback? onTap;

  /// Apply the subtle DS card shadow. Set false for cards sitting on an inset
  /// surface, where the border alone provides enough separation.
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final radius = BorderRadius.circular(SureTokens.radiusLg);

    Widget content = Padding(padding: padding, child: child);
    if (onTap != null) {
      // Material(transparency) gives InkWell a surface to paint on without
      // covering the card's tokenized background or border.
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: onTap, borderRadius: radius, child: content),
      );
    }

    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.container,
        borderRadius: radius,
        border: Border.all(color: palette.borderSecondary),
        boxShadow: elevated ? palette.shadowXs : null,
      ),
      child: content,
    );
  }
}
