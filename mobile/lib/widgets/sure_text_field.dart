import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/sure_colors.dart';
import '../theme/sure_tokens.dart';

/// Sure design-system text field — a tokenized [TextFormField] wrapper mirroring
/// the web DS form field: an optional label above a filled `bg-container` input
/// with a hairline border, rounded corners, a `textSubdued` placeholder, a
/// stronger border on focus, and the destructive token for errors.
///
/// It builds a complete [InputDecoration] from the active [SureColors] palette
/// (rather than leaning on theme defaults), so the chrome is brightness-aware,
/// self-contained, and stays in lockstep with `sure.tokens.json`.
///
/// ```dart
/// SureTextField(
///   controller: _email,
///   label: 'Email',
///   hint: 'you@example.com',
///   keyboardType: TextInputType.emailAddress,
///   prefixIcon: const Icon(Icons.mail_outline),
///   validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
/// )
/// ```
class SureTextField extends StatelessWidget {
  const SureTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.onTap,
    this.focusNode,
    this.autovalidateMode,
  });

  final TextEditingController? controller;

  /// Optional label rendered above the field (DS style — not a Material floating
  /// label, so it stays put and reads like the web `form-field__label`).
  final String? label;

  /// Placeholder text shown when empty (rendered in `textSubdued`).
  final String? hint;

  /// Optional helper text below the field.
  final String? helperText;

  final Widget? prefixIcon;
  final Widget? suffixIcon;

  final bool obscureText;
  final bool enabled;
  final bool readOnly;
  final bool autofocus;

  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;

  final int maxLines;
  final int? minLines;
  final int? maxLength;

  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final AutovalidateMode? autovalidateMode;

  @override
  Widget build(BuildContext context) {
    final palette = SureColors.of(context).palette;
    final theme = Theme.of(context);

    OutlineInputBorder borderOf(Color color, [double width = 1]) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        borderSide: BorderSide(color: color, width: width),
      );
    }

    // An obscured field is single-line by definition; otherwise grow maxLines to
    // cover minLines so a caller passing only minLines can't trip Flutter's
    // `minLines <= maxLines` assert.
    final resolvedMinLines = obscureText ? null : minLines;
    final resolvedMaxLines = obscureText
        ? 1
        : (minLines != null && minLines! > maxLines ? minLines : maxLines);

    final field = TextFormField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      readOnly: readOnly,
      autofocus: autofocus,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      textCapitalization: textCapitalization,
      inputFormatters: inputFormatters,
      maxLines: resolvedMaxLines,
      minLines: resolvedMinLines,
      maxLength: maxLength,
      validator: validator,
      onChanged: onChanged,
      onFieldSubmitted: onFieldSubmitted,
      onTap: onTap,
      autovalidateMode: autovalidateMode,
      style: theme.textTheme.bodyLarge?.copyWith(color: palette.textPrimary),
      cursorColor: palette.textPrimary,
      decoration: InputDecoration(
        hintText: hint,
        helperText: helperText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: palette.container,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        hintStyle: theme.textTheme.bodyLarge?.copyWith(
          color: palette.textSubdued,
        ),
        helperStyle: theme.textTheme.bodySmall?.copyWith(
          color: palette.textSecondary,
        ),
        errorStyle: theme.textTheme.bodySmall?.copyWith(
          color: palette.destructive,
        ),
        errorMaxLines: 2,
        prefixIconColor: palette.textSecondary,
        suffixIconColor: palette.textSecondary,
        border: borderOf(palette.borderSecondary),
        enabledBorder: borderOf(palette.borderSecondary),
        focusedBorder: borderOf(palette.borderPrimary, 1.5),
        disabledBorder: borderOf(palette.borderSubdued),
        errorBorder: borderOf(palette.destructive),
        focusedErrorBorder: borderOf(palette.destructive, 1.5),
      ),
    );

    if (label == null) return field;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The label is shown visually but excluded from semantics; it's attached
        // to the field below instead, so screen readers announce the field with
        // its name (parity with Material's `labelText`) rather than reading a
        // detached label node.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 6),
            child: Text(
              label!,
              style: theme.textTheme.labelMedium?.copyWith(
                color: enabled ? palette.textSecondary : palette.textSubdued,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
        Semantics(label: label, child: field),
      ],
    );
  }
}
