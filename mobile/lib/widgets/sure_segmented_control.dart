import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';

/// One segment of a [SureSegmentedControl].
class SureSegment<T> {
  const SureSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;

  /// Optional leading icon (e.g. an [Icon] or [SureIcon]); tinted to match the
  /// segment's selected/unselected label color.
  final Widget? icon;
}

/// Sure design-system segmented control — a tokenized single-select toggle
/// mirroring the web DS `segmented-control`: an inset track holding equal-width
/// segments, where the selected segment is a raised surface (container fill +
/// the subtle DS shadow) and unselected segments are flat `textSecondary` labels.
///
/// Colors resolve from the active [SureColors] palette, so it's brightness-aware
/// and stays in lockstep with `sure.tokens.json` (and avoids the Material
/// `SegmentedButton` `secondaryContainer` look). Expects a bounded width — the
/// segments share it equally.
///
/// ```dart
/// SureSegmentedControl<String>(
///   selected: nature,
///   onChanged: (v) => setState(() => nature = v),
///   segments: const [
///     SureSegment(value: 'expense', label: 'Expense', icon: Icon(Icons.arrow_downward)),
///     SureSegment(value: 'income', label: 'Income', icon: Icon(Icons.arrow_upward)),
///   ],
/// )
/// ```
class SureSegmentedControl<T> extends StatelessWidget {
  const SureSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  final List<SureSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    // Selection is value-based (segment.value == selected), so duplicate values
    // would render multiple segments as selected at once. Guard in debug builds
    // (a const constructor can't host this non-constant check).
    assert(
      segments.map((s) => s.value).toSet().length == segments.length,
      'SureSegmentedControl requires unique segment values.',
    );
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);
    // The palette has no single "raised surface" token that reads correctly in
    // both modes, so pick the brightness-appropriate one: white-ish in light, a
    // lighter-than-track inset in dark — both sit *above* the track.
    final isLight = theme.brightness == Brightness.light;
    final selectedBg =
        isLight ? palette.container : palette.containerInsetHover;

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.surfaceInset,
        borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        border: Border.all(color: palette.borderSecondary),
      ),
      child: Row(
        children: [
          for (final segment in segments)
            Expanded(
              child: _Segment<T>(
                segment: segment,
                selected: segment.value == selected,
                selectedBg: selectedBg,
                palette: palette,
                textStyle: theme.textTheme.labelLarge,
                onTap: () => onChanged(segment.value),
              ),
            ),
        ],
      ),
    );
  }
}

class _Segment<T> extends StatefulWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.selectedBg,
    required this.palette,
    required this.textStyle,
    required this.onTap,
  });

  final SureSegment<T> segment;
  final bool selected;
  final Color selectedBg;
  final SureTokenPalette palette;
  final TextStyle? textStyle;
  final VoidCallback onTap;

  @override
  State<_Segment<T>> createState() => _SegmentState<T>();
}

class _SegmentState<T> extends State<_Segment<T>> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final selected = widget.selected;
    final fg = selected ? palette.textPrimary : palette.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      // FocusableActionDetector makes each segment keyboard/switch focusable and
      // Enter/Space-activatable (parity with the Material SegmentedButton it
      // replaces), mirroring SureButton — without the Material ripple.
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: selected ? widget.selectedBg : const Color(0x00000000),
              borderRadius: BorderRadius.circular(SureTokens.radiusMd),
              boxShadow: [
                if (selected) ...palette.shadowXs,
                // Non-displacing focus ring so it doesn't shift the layout.
                if (_focused)
                  BoxShadow(
                    color: palette.focusRing,
                    blurRadius: 0,
                    spreadRadius: 2,
                  ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.segment.icon != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(color: fg, size: 18),
                    child: widget.segment.icon!,
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    widget.segment.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: widget.textStyle?.copyWith(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
