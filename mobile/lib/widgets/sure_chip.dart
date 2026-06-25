import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';

/// Sure design-system filter chip — a tokenized selectable pill mirroring the web
/// DS pill: a rounded-full chip that reads as bordered/neutral when unselected
/// and filled (neutral `buttonPrimary` + inverse label) when selected.
///
/// Colors resolve from the active [SureColors] palette, so it's brightness-aware
/// and stays in lockstep with `sure.tokens.json` (and avoids the Material
/// `primaryContainer` tint the raw `FilterChip` falls back to).
///
/// ```dart
/// SureChip(
///   label: 'USD',
///   selected: isSelected,
///   onSelected: (next) => toggle(next),
/// )
/// ```
class SureChip extends StatelessWidget {
  const SureChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onSelected,
    this.leading,
    this.enabled = true,
  });

  final String label;
  final bool selected;

  /// Called with the next selected value when tapped. When null the chip is
  /// non-interactive (still renders its selected/unselected state).
  final ValueChanged<bool>? onSelected;

  /// Optional leading widget (e.g. a color dot or icon).
  final Widget? leading;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    final interactive = enabled && onSelected != null;

    // Selected: filled neutral pill with an inverse label. Unselected: a
    // transparent pill with a hairline border. The border lives on the shape so
    // Material paints it and clips the ink to the stadium.
    final shape = StadiumBorder(
      side: selected
          ? BorderSide.none
          : BorderSide(color: palette.borderSecondary),
    );

    final content = ConstrainedBox(
      // Enforce a comfortable minimum tap target regardless of context
      // (Material FilterChip parity); the chip still sizes to content otherwise.
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 6)],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: selected ? palette.textInverse : palette.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      // Announce as a button only when it's actually tappable; a display-only
      // chip is just a selected indicator, not a disabled button.
      button: interactive ? true : null,
      enabled: interactive ? true : null,
      selected: selected,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Material(
          color: selected ? palette.buttonPrimary : const Color(0x00000000),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: interactive ? () => onSelected!(!selected) : null,
            customBorder: shape,
            child: content,
          ),
        ),
      ),
    );
  }
}
