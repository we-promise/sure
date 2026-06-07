import 'package:flutter/material.dart';

import 'sure_tokens.dart';

class SureTheme {
  const SureTheme._();

  static ThemeData get light => _build(SureTokens.light, Brightness.light);

  static ThemeData get dark => _build(SureTokens.dark, Brightness.dark);

  static ThemeData _build(SureTokenPalette tokens, Brightness brightness) {
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: tokens.link,
      onPrimary: tokens.textInverse,
      secondary: tokens.info,
      onSecondary: tokens.textInverse,
      error: tokens.destructive,
      onError: tokens.textInverse,
      errorContainer: tokens.destructiveSubtle,
      onErrorContainer: tokens.textPrimary,
      surface: tokens.surface,
      onSurface: tokens.textPrimary,
      surfaceContainerHighest: tokens.containerInset,
      outline: tokens.borderSecondary,
      outlineVariant: tokens.borderSubdued,
    );

    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(SureTokens.radiusLg),
      borderSide: BorderSide(color: tokens.borderSecondary),
    );

    final base = ThemeData(
      fontFamily: SureTokens.fontSans,
      fontFamilyFallback: SureTokens.fontFallback,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: tokens.surface,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: tokens.surface,
        foregroundColor: tokens.textPrimary,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: tokens.container,
        surfaceTintColor: Colors.transparent,
        shadowColor: tokens.shadow,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureTokens.radiusLg),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: inputBorder,
        enabledBorder: inputBorder,
        focusedBorder: inputBorder.copyWith(
          borderSide: BorderSide(color: tokens.borderPrimary),
        ),
        filled: true,
        fillColor: tokens.container,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 50),
          backgroundColor: tokens.buttonPrimary,
          foregroundColor: tokens.textInverse,
          disabledBackgroundColor: tokens.containerInset,
          disabledForegroundColor: tokens.textSubdued,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureTokens.radiusLg),
          ),
        ),
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: tokens.textPrimary,
        displayColor: tokens.textPrimary,
      ),
      primaryTextTheme: base.primaryTextTheme.apply(
        bodyColor: tokens.textPrimary,
        displayColor: tokens.textPrimary,
      ),
    );
  }
}
