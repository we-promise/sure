import 'package:flutter/material.dart';
import 'design_system.dart';

/// Theme builder that creates Flutter ThemeData from the Sure design system.
///
/// This ensures visual consistency between the Flutter app and the Rails web app.
class SureTheme {
  SureTheme._();

  /// Primary brand color (indigo-500 from design system)
  static const Color _primaryColor = SureColors.indigo500;

  /// Creates the light theme.
  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _primaryColor,
        brightness: Brightness.light,
        surface: SureColors.gray50,
        onSurface: SureColors.gray900,
        primary: _primaryColor,
        onPrimary: SureColors.white,
        secondary: SureColors.gray500,
        onSecondary: SureColors.white,
        error: SureColors.red600,
        onError: SureColors.white,
      ),
      scaffoldBackgroundColor: SureColors.gray50,
      cardColor: SureColors.white,
      dividerColor: SureColors.gray200,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: SureColors.white,
        foregroundColor: SureColors.gray900,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: SureColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          side: const BorderSide(color: SureColors.gray200),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SureColors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.gray200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.gray200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: BorderSide(color: _primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.red600),
        ),
        labelStyle: const TextStyle(color: SureColors.gray500),
        hintStyle: const TextStyle(color: SureColors.gray400),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          backgroundColor: SureColors.gray900,
          foregroundColor: SureColors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          foregroundColor: SureColors.gray900,
          side: const BorderSide(color: SureColors.gray200),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _primaryColor,
        ),
      ),
      iconTheme: const IconThemeData(
        color: SureColors.gray500,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: SureColors.white,
        selectedItemColor: SureColors.gray900,
        unselectedItemColor: SureColors.gray400,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _primaryColor,
        foregroundColor: SureColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.lg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SureColors.gray900,
        contentTextStyle: const TextStyle(color: SureColors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: SureColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.xl),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: SureColors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(SureBorderRadius.xl),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: SureColors.gray100,
        selectedColor: _primaryColor.withValues(alpha: 0.2),
        labelStyle: const TextStyle(color: SureColors.gray900),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      textTheme: _buildTextTheme(Brightness.light),
    );
  }

  /// Creates the dark theme.
  static ThemeData dark() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: _primaryColor,
        brightness: Brightness.dark,
        surface: SureColors.black,
        onSurface: SureColors.white,
        primary: _primaryColor,
        onPrimary: SureColors.white,
        secondary: SureColors.gray400,
        onSecondary: SureColors.black,
        error: SureColors.red400,
        onError: SureColors.black,
      ),
      scaffoldBackgroundColor: SureColors.black,
      cardColor: SureColors.gray900,
      dividerColor: SureColors.gray700,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        backgroundColor: SureColors.gray900,
        foregroundColor: SureColors.white,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: SureColors.gray900,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          side: const BorderSide(color: SureColors.gray700),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SureColors.gray900,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.gray700),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.gray700),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: BorderSide(color: _primaryColor, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
          borderSide: const BorderSide(color: SureColors.red400),
        ),
        labelStyle: const TextStyle(color: SureColors.gray400),
        hintStyle: const TextStyle(color: SureColors.gray500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          backgroundColor: SureColors.white,
          foregroundColor: SureColors.gray900,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          ),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
          foregroundColor: SureColors.white,
          side: const BorderSide(color: SureColors.gray700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SureBorderRadius.lg),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: _primaryColor,
        ),
      ),
      iconTheme: const IconThemeData(
        color: SureColors.gray400,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: SureColors.gray900,
        selectedItemColor: SureColors.white,
        unselectedItemColor: SureColors.gray500,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: _primaryColor,
        foregroundColor: SureColors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.lg),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SureColors.gray800,
        contentTextStyle: const TextStyle(color: SureColors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: SureColors.gray900,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.xl),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: SureColors.gray900,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(SureBorderRadius.xl),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: SureColors.gray800,
        selectedColor: _primaryColor.withValues(alpha: 0.3),
        labelStyle: const TextStyle(color: SureColors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SureBorderRadius.md),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
      textTheme: _buildTextTheme(Brightness.dark),
    );
  }

  /// Builds the text theme for the given brightness.
  static TextTheme _buildTextTheme(Brightness brightness) {
    final Color primaryTextColor =
        brightness == Brightness.dark ? SureColors.white : SureColors.gray900;
    final Color secondaryTextColor = brightness == Brightness.dark
        ? SureColors.gray300
        : SureColors.gray500;

    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
        letterSpacing: -0.25,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
      ),
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        color: primaryTextColor,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: primaryTextColor,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: primaryTextColor,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
        letterSpacing: 0.15,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
        letterSpacing: 0.1,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
        letterSpacing: 0.5,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: primaryTextColor,
        letterSpacing: 0.25,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: secondaryTextColor,
        letterSpacing: 0.4,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
        letterSpacing: 0.1,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: primaryTextColor,
        letterSpacing: 0.5,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: secondaryTextColor,
        letterSpacing: 0.5,
      ),
    );
  }
}
