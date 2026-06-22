import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../theme/sure_tokens.dart';
import '../theme/sure_typography.dart';

/// Sure design-system button variants, mirroring the web `DS::Button`
/// (`DS::Buttonish::VARIANTS`).
enum SureButtonVariant { primary, secondary, destructive, outline, ghost }

/// Button sizes, mirroring the web `DS::Buttonish::SIZES` (sm/md/lg ≈ 28/36/48).
enum SureButtonSize { sm, md, lg }

/// Sure design-system button — a custom, non-Material control mirroring the web
/// `DS::Button`: tokenized variant colors, `font-medium` label, sizes, and a
/// flat custom press feedback (no Material ripple). `onPressed: null` (or
/// [loading]) renders a disabled button.
///
/// Colors resolve from the active [SureColors] palette, so the button is
/// brightness-aware and stays in lockstep with `sure.tokens.json`.
class SureButton extends StatefulWidget {
  final String label;

  /// Tap handler. When null the button is disabled (50% opacity, no taps).
  final VoidCallback? onPressed;

  final SureButtonVariant variant;
  final SureButtonSize size;

  /// Optional leading widget (e.g. a `SureIcon`), kept decoupled so the button
  /// doesn't depend on any specific icon implementation.
  final Widget? leading;

  /// Stretch to the available width (mirrors `full_width`).
  final bool fullWidth;

  /// Show an adaptive spinner in place of the leading slot and disable taps.
  final bool loading;

  const SureButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = SureButtonVariant.primary,
    this.size = SureButtonSize.md,
    this.leading,
    this.fullWidth = false,
    this.loading = false,
  });

  @override
  State<SureButton> createState() => _SureButtonState();
}

class _SureButtonState extends State<SureButton> {
  bool _pressed = false;
  bool _focused = false;

  bool get _enabled => widget.onPressed != null && !widget.loading;

  @override
  void didUpdateWidget(covariant SureButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the button is disabled mid-press, onTapUp/onTapCancel never fire — so
    // clear the pressed state here to avoid it sticking on once re-enabled.
    if (!_enabled) {
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final style = _SureButtonStyle.resolve(widget.variant, palette);
    final metrics = _SureButtonMetrics.resolve(widget.size);

    final background = _pressed && _enabled ? style.pressedBackground : style.background;

    final label = Text(
      widget.label,
      style: TextStyle(
        color: style.foreground,
        fontSize: metrics.fontSize,
        fontWeight: FontWeight.w500,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    // Build the spinner per-platform so the foreground tint is honored on both:
    // CircularProgressIndicator.adaptive renders a CupertinoActivityIndicator on
    // Apple platforms, which ignores `valueColor`, so pass `color` to it directly.
    final platform = Theme.of(context).platform;
    final isCupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    final leading = widget.loading
        ? SizedBox(
            width: metrics.fontSize,
            height: metrics.fontSize,
            child: isCupertino
                ? CupertinoActivityIndicator(
                    color: style.foreground,
                    radius: metrics.fontSize / 2,
                  )
                : CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(style.foreground),
                  ),
          )
        : widget.leading;

    final content = Row(
      mainAxisSize: widget.fullWidth ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: SureSpacing.md)],
        // Flex only when full-width (bounded). A bare Flexible in a min-size Row
        // asserts under unbounded horizontal constraints, so an inline button
        // passes the self-sizing label directly.
        if (widget.fullWidth) Flexible(child: label) else label,
      ],
    );

    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 80),
      constraints: BoxConstraints(minHeight: metrics.height),
      padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(metrics.radius),
        border: style.border == null
            ? null
            : Border.all(color: style.border!),
        // Keyboard/switch-control focus ring (drawn as a non-displacing ring so
        // it doesn't shift layout). borderPrimary is brightness-aware.
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: palette.borderPrimary,
                  blurRadius: 0,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Center(widthFactor: widget.fullWidth ? null : 1.0, child: content),
    );

    return Semantics(
      button: true,
      enabled: _enabled,
      label: widget.loading ? '${widget.label}, loading' : widget.label,
      child: FocusableActionDetector(
        enabled: _enabled,
        mouseCursor:
            _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              if (_enabled) widget.onPressed?.call();
              return null;
            },
          ),
        },
        child: Opacity(
          opacity: _enabled ? 1.0 : 0.5,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Keep all tap callbacks present (a stable gesture arena) and gate
            // on `_enabled` inside them. Swapping them to null when the button
            // is disabled mid-press would dispose the recognizer during the
            // rebuild and fire onTapCancel -> setState() during build.
            onTapDown: (_) {
              if (_enabled) setState(() => _pressed = true);
            },
            onTapUp: (_) {
              if (_pressed) setState(() => _pressed = false);
            },
            onTapCancel: () {
              if (_pressed) setState(() => _pressed = false);
            },
            onTap: () {
              if (_enabled) widget.onPressed?.call();
            },
            child: button,
          ),
        ),
      ),
    );
  }
}

class _SureButtonStyle {
  const _SureButtonStyle({
    required this.background,
    required this.pressedBackground,
    required this.foreground,
    this.border,
  });

  final Color background;
  final Color pressedBackground;
  final Color foreground;
  final Color? border;

  static _SureButtonStyle resolve(
    SureButtonVariant variant,
    SureTokenPalette p,
  ) {
    switch (variant) {
      case SureButtonVariant.primary:
        return _SureButtonStyle(
          background: p.buttonPrimary,
          pressedBackground: p.buttonPrimaryHover,
          foreground: p.textInverse,
        );
      case SureButtonVariant.destructive:
        return _SureButtonStyle(
          background: p.buttonDestructive,
          pressedBackground: p.buttonDestructiveHover,
          foreground: p.textInverse,
        );
      case SureButtonVariant.secondary:
        return _SureButtonStyle(
          background: p.surfaceInset,
          pressedBackground: p.surfaceInsetHover,
          foreground: p.textPrimary,
        );
      case SureButtonVariant.outline:
        return _SureButtonStyle(
          background: const Color(0x00000000),
          pressedBackground: p.surfaceHover,
          foreground: p.textPrimary,
          border: p.borderSecondary,
        );
      case SureButtonVariant.ghost:
        return _SureButtonStyle(
          background: const Color(0x00000000),
          pressedBackground: p.surfaceHover,
          foreground: p.textPrimary,
        );
    }
  }
}

class _SureButtonMetrics {
  const _SureButtonMetrics({
    required this.height,
    required this.horizontalPadding,
    required this.fontSize,
    required this.radius,
  });

  final double height;
  final double horizontalPadding;
  final double fontSize;
  final double radius;

  static _SureButtonMetrics resolve(SureButtonSize size) {
    switch (size) {
      case SureButtonSize.sm:
        return const _SureButtonMetrics(
          height: 28,
          horizontalPadding: SureSpacing.lg,
          fontSize: SureTypography.sm,
          radius: SureTokens.radiusMd,
        );
      case SureButtonSize.md:
        return const _SureButtonMetrics(
          height: 36,
          horizontalPadding: SureSpacing.xl,
          fontSize: SureTypography.sm,
          radius: SureTokens.radiusLg,
        );
      case SureButtonSize.lg:
        return const _SureButtonMetrics(
          height: 48,
          horizontalPadding: SureSpacing.xxl,
          fontSize: SureTypography.base,
          radius: SureTokens.radiusLg,
        );
    }
  }
}
