import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';
import 'sure_button.dart';

/// Sure design-system modal dialog — a tokenized replacement for the Material
/// [AlertDialog]. It renders a rounded `container` surface with a hairline
/// border and the DS elevation shadow, a semibold title, optional body, and a
/// trailing actions row (typically [SureButton]s).
///
/// Colors resolve from the active [SureColors] palette, so it is brightness-
/// aware and stays in lockstep with `sure.tokens.json` instead of inheriting
/// Material's `AlertDialog` chrome. The [Dialog] wrapper is kept transparent and
/// only provides the modal route's centering/inset/safe-area — every visible
/// pixel is Sure-tokenized.
class SureDialog extends StatelessWidget {
  const SureDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.actions = const [],
  }) : assert(
          message == null || content == null,
          'Provide either message or content, not both',
        );

  /// Dialog heading.
  final String title;

  /// Convenience body text. Mutually exclusive with [content].
  final String? message;

  /// Arbitrary body content (e.g. a form field). Mutually exclusive with
  /// [message].
  final Widget? content;

  /// Footer actions, laid out trailing-aligned and wrapping to a vertical stack
  /// when they don't fit. Usually [SureButton]s.
  final List<Widget> actions;

  /// Show a confirm/cancel dialog and resolve to the user's choice: `true`
  /// (confirmed), `false` (cancelled), or `null` (dismissed via barrier/back).
  ///
  /// Set [destructive] to render the confirm action in the destructive variant.
  /// Set [confirmEnabled] to `false` to render a disabled confirm action (e.g.
  /// while a precondition like a store URL is unmet).
  static Future<bool?> confirm(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    required String cancelLabel,
    String? message,
    bool destructive = false,
    bool confirmEnabled = true,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => SureDialog(
        title: title,
        message: message,
        actions: [
          SureButton(
            label: cancelLabel,
            variant: SureButtonVariant.ghost,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          SureButton(
            label: confirmLabel,
            variant: destructive
                ? SureButtonVariant.destructive
                : SureButtonVariant.primary,
            onPressed: confirmEnabled ? () => Navigator.pop(ctx, true) : null,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;

    // Bound the body to the available dialog height and let it scroll, so
    // large content (long lists, forms) doesn't overflow on small screens —
    // matching Material AlertDialog's scrollable content area. The body is a
    // Flexible (loose) child of the Column: short content sizes naturally,
    // tall content is capped and scrolls. Caller-supplied [content] keeps its
    // own scrollable; a plain [message] is wrapped in one here.
    Widget? body;
    if (content != null) {
      body = Flexible(child: content!);
    } else if (message != null) {
      body = Flexible(
        child: SingleChildScrollView(
          child: Text(
            message!,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: palette.textSecondary,
            ),
          ),
        ),
      );
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: palette.container,
          borderRadius: BorderRadius.circular(SureTokens.radiusLg),
          border: Border.all(color: palette.borderSecondary),
          boxShadow: palette.shadowLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 12),
              body,
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 24),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                children: actions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
