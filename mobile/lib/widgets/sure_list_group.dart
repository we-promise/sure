import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';
import 'sure_icon.dart';

/// Sure design-system grouped list — a tokenized container that stacks
/// [SureListRow]s behind a single rounded surface with a hairline border, the
/// subtle DS shadow, and inset dividers between rows. Mirrors the web grouped
/// inset list (`bg-container` + `rounded-lg` + `shadow-border-xs`, rows clipped
/// and separated by `border-divider`).
///
/// Colors resolve from the active [SureColors] palette, so the chrome stays in
/// lockstep with `sure.tokens.json` and reads correctly in light and dark.
///
/// ```dart
/// SureListGroup(
///   header: 'Tools',
///   children: [
///     SureListRow(title: 'Calendar', subtitle: 'Monthly view', showChevron: true, onTap: ...),
///     SureListRow(title: 'Recent', showChevron: true, onTap: ...),
///   ],
/// )
/// ```
class SureListGroup extends StatelessWidget {
  const SureListGroup({
    super.key,
    required this.children,
    this.header,
    this.margin,
  });

  /// Rows to stack — typically [SureListRow]s. Dividers are inserted between
  /// them automatically (never before the first or after the last).
  final List<Widget> children;

  /// Optional uppercase section label rendered above the group.
  final String? header;

  /// Outer spacing around the group (e.g. separation between sections).
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    final palette = SureColors.of(context).palette;
    final radius = BorderRadius.circular(SureTokens.radiusLg);

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        // Inset hairline between rows, lighter than the group's edge so the
        // separators read as internal (classic grouped-list look).
        rows.add(Divider(
          height: 1,
          thickness: 1,
          indent: 16,
          endIndent: 16,
          color: palette.borderSubdued,
        ));
      }
      rows.add(children[i]);
    }

    final group = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: palette.container,
        borderRadius: radius,
        border: Border.all(color: palette.borderSecondary),
        boxShadow: palette.shadowXs,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );

    final content = header == null
        ? group
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Text(
                  header!.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: palette.textSecondary,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.4,
                      ),
                ),
              ),
              group,
            ],
          );

    if (margin == null) return content;
    return Padding(padding: margin!, child: content);
  }
}

/// A single row inside a [SureListGroup]. Lays out an optional [leading] widget,
/// a [title] (+ optional [subtitle]), and a trailing affordance — either an
/// explicit [trailing] widget or a DS chevron when [showChevron] is set.
///
/// The row paints no background or border of its own; it relies on the enclosing
/// [SureListGroup] for chrome, dividers, and corner clipping. When [onTap] is
/// provided the whole row is tappable with a flat ink response (clipped to the
/// group's rounded corners by the group's `antiAlias`).
class SureListRow extends StatelessWidget {
  const SureListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.showChevron = false,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;

  /// Leading widget (e.g. an icon badge). Caller's choice — the row is
  /// icon-agnostic.
  final Widget? leading;

  /// Trailing widget (e.g. a value or switch). Takes precedence over
  /// [showChevron] when both are provided.
  final Widget? trailing;

  /// When non-null, the row is tappable.
  final VoidCallback? onTap;

  /// Show a DS chevron disclosure indicator on the trailing edge. Ignored when
  /// an explicit [trailing] is provided.
  final bool showChevron;

  /// Render the title in the destructive token (for delete/reset actions).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);

    Widget? trailingWidget = trailing;
    if (trailingWidget == null && showChevron) {
      trailingWidget = SureIcon(
        SureIcons.chevronRight,
        size: SureIconSize.md,
        color: palette.textSubdued,
      );
    }

    Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color:
                        destructive ? palette.destructive : palette.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: palette.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailingWidget != null) ...[
            const SizedBox(width: 12),
            trailingWidget,
          ],
        ],
      ),
    );

    if (onTap != null) {
      // Material(transparency) gives the InkWell a surface to paint on without
      // covering the group's tokenized background. No borderRadius here — the
      // group clips the ripple to its rounded corners via clipBehavior.
      // MergeSemantics + Semantics(button) restores the button/enabled flags a
      // Material ListTile exposes, so screen readers still announce the whole
      // row as a single button (parity with the pre-migration ListTile rows).
      content = MergeSemantics(
        child: Semantics(
          button: true,
          enabled: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(onTap: onTap, child: content),
          ),
        ),
      );
    }

    return content;
  }
}
