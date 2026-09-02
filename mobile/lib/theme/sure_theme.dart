import 'package:flutter/material.dart';

import 'sure_colors.dart';
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
      // The container roles were unset, so on screens not yet redesigned with
      // SureColors (e.g. Chats) Material defaulted them to a blue that read as
      // off-brand on FAB/badge/avatar surfaces. Pin them to a neutral Sure
      // surface with primary text on top. `primary`/`secondary` stay link/info so
      // existing link/accent callers are unchanged; the prominent neutral primary
      // action color is applied to FABs via floatingActionButtonTheme below.
      primaryContainer: tokens.surfaceInset,
      onPrimaryContainer: tokens.textPrimary,
      secondary: tokens.info,
      onSecondary: tokens.textInverse,
      secondaryContainer: tokens.surfaceInset,
      onSecondaryContainer: tokens.textPrimary,
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
      extensions: <ThemeExtension<dynamic>>[SureColors(tokens)],
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
          minimumSize: const Size(double.infinity, 50),
          backgroundColor: tokens.buttonPrimary,
          foregroundColor: tokens.textInverse,
          disabledBackgroundColor: tokens.containerInset,
          disabledForegroundColor: tokens.textSubdued,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureTokens.radiusLg),
          ),
        ),
      ),
      // The FAB is Sure's primary action surface — use the neutral brand primary
      // (near-black in light, white in dark) so it reads as the prominent action
      // instead of the subtle primaryContainer the Material 3 default would use.
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: tokens.buttonPrimary,
        foregroundColor: tokens.textInverse,
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
