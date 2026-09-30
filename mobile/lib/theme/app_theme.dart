import 'package:flutter/material.dart';
import 'dart:ui' show FontFeature;

import 'sure_colors.dart';
import 'sure_tokens.dart';

// ---------------------------------------------------------------------------
// Sure mobile — design system (redesign/ui)
//
// A self-contained theme: neutral light/dark palettes, semantic green/red for
// money flows, an 8pt spacing grid, 12–16 radii, and a Geist type scale with
// tabular-figure styles for amounts.
//
// Usage:
//   AppTheme.light / AppTheme.dark  -> MaterialApp(theme:, darkTheme:)
//   AppColors.of(context)           -> semantic palette (also context.colors)
//   AppSpacing.* / AppRadius.*        -> layout tokens
//   AppText.amount*(...)            -> tabular-figure styles for money
// ---------------------------------------------------------------------------

/// 8pt layout grid. [xs] (4) is the half step; the canonical rhythm is
/// 8 / 16 / 24 / 32 / 48.
class AppSpacing {
  const AppSpacing._();

  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double base = 16.0;
  static const double lg = 20.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 40.0;
  static const double huge = 48.0;

  /// Standard horizontal padding for screen content.
  static const EdgeInsets pageH = EdgeInsets.symmetric(horizontal: base);

  /// Standard padding inside cards.
  static const EdgeInsets card = EdgeInsets.all(base);

  /// Standard padding for list tiles / form rows.
  static const EdgeInsets row =
      EdgeInsets.symmetric(horizontal: base, vertical: md);
}

/// Corner radii. Cards and sheets sit in the 12–16 range; small controls use
/// [sm], dialogs and bottom sheets [xl].
class AppRadius {
  const AppRadius._();

  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double pill = 999.0;

  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius control = BorderRadius.all(Radius.circular(md));
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius sheet =
      BorderRadius.vertical(top: Radius.circular(xl));
}

/// Semantic palette, exposed as a [ThemeExtension] so widgets resolve the
/// correct values for the active brightness via [AppColors.of].
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceInverse,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textOnInverse,
    required this.primary,
    required this.onPrimary,
    required this.income,
    required this.incomeSubtle,
    required this.expense,
    required this.expenseSubtle,
    required this.info,
    required this.infoSubtle,
    required this.warning,
    required this.warningSubtle,
    required this.overlay,
    required this.shadow,
  });

  /// Scaffold background.
  final Color bg;

  /// Cards, sheets, dialogs, app bars.
  final Color surface;

  /// Insets: filled text fields, chips, icon badges, skeleton blocks.
  final Color surfaceAlt;

  /// Inverse surface (snackbars, tooltips).
  final Color surfaceInverse;

  /// Hairline borders (cards, dividers, unselected chips).
  final Color border;

  /// Emphasized borders (inputs at rest, outlined buttons).
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textOnInverse;

  /// Prominent neutral action color (primary buttons, FAB, selected states).
  /// Near-black in light mode, near-white in dark mode.
  final Color primary;
  final Color onPrimary;

  /// Money in / positive deltas / success.
  final Color income;
  final Color incomeSubtle;

  /// Money out / negative deltas / destructive.
  final Color expense;
  final Color expenseSubtle;

  /// Links, pending sync, informational highlights.
  final Color info;
  final Color infoSubtle;

  /// Warnings, offline state.
  final Color warning;
  final Color warningSubtle;

  /// Modal scrim.
  final Color overlay;

  /// Shadow tint (used with low opacity).
  final Color shadow;

  /// The active palette for [context]. Falls back to the palette matching the
  /// ambient brightness when the extension is missing (e.g. a widget pumped
  /// without [AppTheme] in a test).
  static AppColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppTheme.darkColors
            : AppTheme.lightColors);
  }

  @override
  AppColors copyWith({
    Color? bg,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceInverse,
    Color? border,
    Color? borderStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textOnInverse,
    Color? primary,
    Color? onPrimary,
    Color? income,
    Color? incomeSubtle,
    Color? expense,
    Color? expenseSubtle,
    Color? info,
    Color? infoSubtle,
    Color? warning,
    Color? warningSubtle,
    Color? overlay,
    Color? shadow,
  }) {
    return AppColors(
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceInverse: surfaceInverse ?? this.surfaceInverse,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textOnInverse: textOnInverse ?? this.textOnInverse,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      income: income ?? this.income,
      incomeSubtle: incomeSubtle ?? this.incomeSubtle,
      expense: expense ?? this.expense,
      expenseSubtle: expenseSubtle ?? this.expenseSubtle,
      info: info ?? this.info,
      infoSubtle: infoSubtle ?? this.infoSubtle,
      warning: warning ?? this.warning,
      warningSubtle: warningSubtle ?? this.warningSubtle,
      overlay: overlay ?? this.overlay,
      shadow: shadow ?? this.shadow,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      surfaceInverse: Color.lerp(surfaceInverse, other.surfaceInverse, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textOnInverse: Color.lerp(textOnInverse, other.textOnInverse, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      income: Color.lerp(income, other.income, t)!,
      incomeSubtle: Color.lerp(incomeSubtle, other.incomeSubtle, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      expenseSubtle: Color.lerp(expenseSubtle, other.expenseSubtle, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoSubtle: Color.lerp(infoSubtle, other.infoSubtle, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSubtle: Color.lerp(warningSubtle, other.warningSubtle, t)!,
      overlay: Color.lerp(overlay, other.overlay, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
    );
  }
}

/// Ergonomic shortcuts for widgets.
extension AppThemeContext on BuildContext {
  AppColors get colors => AppColors.of(this);
  ThemeData get theme => Theme.of(this);
  TextTheme get textTheme => Theme.of(this).textTheme;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

/// Type scale + money styles. Body/title styles live on [ThemeData.textTheme];
/// amounts use the helpers here so every money figure renders with tabular
/// (monospaced) digits and never jitter while values change.
class AppText {
  const AppText._();

  static const String fontSans = 'Geist';
  static const String fontMono = 'Geist Mono';
  static const List<String> fontFallback = <String>[
    'Inter',
    'Arial',
    'sans-serif'
  ];

  static const FontFeature _tabular = FontFeature.tabularFigures();

  /// Tabular-figure style for money amounts (Geist with the `tnum` feature).
  static TextStyle amount(
    double size, {
    FontWeight weight = FontWeight.w600,
    Color? color,
    double height = 1.15,
    double letterSpacing = -0.2,
  }) {
    return TextStyle(
      fontFamily: fontSans,
      fontFamilyFallback: fontFallback,
      fontFeatures: const <FontFeature>[_tabular],
      fontSize: size,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
      color: color,
    );
  }

  /// Monospace style for account numbers, IDs, log lines.
  static TextStyle mono(double size,
      {FontWeight weight = FontWeight.w400, Color? color}) {
    return TextStyle(
      fontFamily: fontMono,
      fontFamilyFallback: fontFallback,
      fontSize: size,
      fontWeight: weight,
      color: color,
    );
  }

  // Canonical amount sizes.
  static TextStyle get amountHero =>
      amount(36, weight: FontWeight.w700, letterSpacing: -0.8);
  static TextStyle get amountXl =>
      amount(28, weight: FontWeight.w700, letterSpacing: -0.5);
  static TextStyle get amountLg => amount(22, weight: FontWeight.w600);
  static TextStyle get amountMd => amount(16, weight: FontWeight.w600);
  static TextStyle get amountSm => amount(14, weight: FontWeight.w500);
  static TextStyle get amountXs => amount(12, weight: FontWeight.w500);
}

class AppTheme {
  const AppTheme._();

  static ThemeData get light => _build(AppTheme.lightColors, Brightness.light);
  static ThemeData get dark => _build(AppTheme.darkColors, Brightness.dark);

  // -------------------------------------------------------------------------
  // Palettes
  // -------------------------------------------------------------------------

  static const AppColors lightColors = AppColors(
    bg: Color(0xFFF7F7F5),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF0F0ED),
    surfaceInverse: Color(0xFF232528),
    border: Color(0xFFE5E5E1),
    borderStrong: Color(0xFFD4D4CF),
    textPrimary: Color(0xFF16181A),
    textSecondary: Color(0xFF5D6167),
    textTertiary: Color(0xFF8E939A),
    textOnInverse: Color(0xFFF2F4F5),
    primary: Color(0xFF16181A),
    onPrimary: Color(0xFFFFFFFF),
    income: Color(0xFF067647),
    incomeSubtle: Color(0xFFE5F5EB),
    expense: Color(0xFFD92D20),
    expenseSubtle: Color(0xFFFCEBE9),
    info: Color(0xFF1570EF),
    infoSubtle: Color(0xFFE8F1FE),
    warning: Color(0xFFB54708),
    warningSubtle: Color(0xFFFDF2E4),
    overlay: Color(0x5216181A),
    shadow: Color(0x140B0B0B),
  );

  static const AppColors darkColors = AppColors(
    bg: Color(0xFF0D0E10),
    surface: Color(0xFF16181A),
    surfaceAlt: Color(0xFF212427),
    surfaceInverse: Color(0xFFE9EBEC),
    border: Color(0xFF2B2E32),
    borderStrong: Color(0xFF3D4147),
    textPrimary: Color(0xFFF2F4F5),
    textSecondary: Color(0xFFA5AAB1),
    textTertiary: Color(0xFF73787F),
    textOnInverse: Color(0xFF16181A),
    primary: Color(0xFFF2F4F5),
    onPrimary: Color(0xFF16181A),
    income: Color(0xFF32D583),
    incomeSubtle: Color(0xFF12311F),
    expense: Color(0xFFF97066),
    expenseSubtle: Color(0xFF3A1A17),
    info: Color(0xFF53A1FB),
    infoSubtle: Color(0xFF16283F),
    warning: Color(0xFFFDB022),
    warningSubtle: Color(0xFF3A2A10),
    overlay: Color(0x99000000),
    shadow: Color(0x66000000),
  );

  // -------------------------------------------------------------------------
  // Theme construction
  // -------------------------------------------------------------------------

  static ThemeData _build(AppColors c, Brightness brightness) {
    final isLight = brightness == Brightness.light;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: c.primary,
      onPrimary: c.onPrimary,
      primaryContainer: c.surfaceAlt,
      onPrimaryContainer: c.textPrimary,
      secondary: c.info,
      onSecondary: isLight ? Colors.white : const Color(0xFF0D0E10),
      secondaryContainer: c.infoSubtle,
      onSecondaryContainer: c.info,
      tertiary: c.income,
      onTertiary: isLight ? Colors.white : const Color(0xFF0D0E10),
      tertiaryContainer: c.incomeSubtle,
      onTertiaryContainer: c.income,
      error: c.expense,
      onError: isLight ? Colors.white : const Color(0xFF0D0E10),
      errorContainer: c.expenseSubtle,
      onErrorContainer: c.expense,
      surface: c.surface,
      onSurface: c.textPrimary,
      onSurfaceVariant: c.textSecondary,
      surfaceContainerLowest:
          isLight ? const Color(0xFFFFFFFF) : const Color(0xFF101114),
      surfaceContainerLow:
          isLight ? const Color(0xFFFBFBFA) : const Color(0xFF16181A),
      surfaceContainer:
          isLight ? const Color(0xFFF7F7F5) : const Color(0xFF1B1E21),
      surfaceContainerHigh:
          isLight ? const Color(0xFFF0F0ED) : const Color(0xFF212427),
      surfaceContainerHighest:
          isLight ? const Color(0xFFE9E9E6) : const Color(0xFF2B2E32),
      inverseSurface: c.surfaceInverse,
      onInverseSurface: c.textOnInverse,
      inversePrimary:
          isLight ? const Color(0xFFD5D7DA) : const Color(0xFF303438),
      outline: c.borderStrong,
      outlineVariant: c.border,
      shadow: c.shadow,
      scrim: c.overlay,
    );

    final textTheme = _textTheme(c);

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: c.bg,
      fontFamily: AppText.fontSans,
      fontFamilyFallback: AppText.fontFallback,
      textTheme: textTheme,
      iconTheme: IconThemeData(color: c.textSecondary, size: 24),
      extensions: <ThemeExtension<dynamic>>[
        c,
        // TEMP (redesign migration): keep the legacy Sure palette extension
        // registered so not-yet-rewritten screens resolve their token colors
        // unchanged. Removed in the cleanup phase together with lib/theme/sure_*.
        SureColors(isLight ? SureTokens.light : SureTokens.dark),
      ],
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleMedium,
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 64,
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: c.shadow,
        indicatorColor: c.surfaceAlt,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontFamily: AppText.fontSans,
            fontSize: 11,
            height: 1.2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? c.textPrimary : c.textTertiary,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 24,
            color: selected ? c.textPrimary : c.textTertiary,
          );
        }),
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.card,
          side: BorderSide(color: c.border),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.xl)),
        ),
        titleTextStyle: textTheme.titleLarge,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: c.textSecondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: c.overlay,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheet),
        dragHandleColor: c.borderStrong,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: c.onPrimary,
          disabledBackgroundColor: c.surfaceAlt,
          disabledForegroundColor: c.textTertiary,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: c.primary,
          foregroundColor: c.onPrimary,
          disabledBackgroundColor: c.surfaceAlt,
          disabledForegroundColor: c.textTertiary,
          elevation: 0,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          disabledForegroundColor: c.textTertiary,
          side: BorderSide(color: c.borderStrong),
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.base),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.textPrimary,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        elevation: 2,
        highlightElevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceAlt,
        hintStyle: textTheme.bodyMedium?.copyWith(color: c.textTertiary),
        labelStyle: textTheme.bodyMedium?.copyWith(color: c.textSecondary),
        floatingLabelStyle:
            textTheme.bodyMedium?.copyWith(color: c.textPrimary),
        errorStyle: textTheme.bodySmall?.copyWith(color: c.expense),
        helperStyle: textTheme.bodySmall?.copyWith(color: c.textTertiary),
        prefixIconColor: c.textTertiary,
        suffixIconColor: c.textTertiary,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.base, vertical: 14),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide(color: c.textPrimary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide(color: c.expense),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide(color: c.expense, width: 1.5),
        ),
        disabledBorder: const OutlineInputBorder(
          borderRadius: AppRadius.control,
          borderSide: BorderSide.none,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surfaceAlt,
        disabledColor: c.surfaceAlt,
        selectedColor:
            isLight ? const Color(0xFFE3E5E8) : const Color(0xFF2E3237),
        checkmarkColor: c.textPrimary,
        side: BorderSide.none,
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium,
        padding:
            const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.chip),
        showCheckmark: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.surfaceInverse,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: c.textOnInverse),
        actionTextColor:
            isLight ? const Color(0xFF9FC3FF) : const Color(0xFF1570EF),
        closeIconColor: c.textOnInverse,
        elevation: 2,
        insetPadding: const EdgeInsets.all(AppSpacing.base),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
      ),
      dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
      listTileTheme: ListTileThemeData(
        iconColor: c.textSecondary,
        textColor: c.textPrimary,
        titleTextStyle:
            textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle:
            textTheme.bodySmall?.copyWith(color: c.textSecondary),
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.base, vertical: 2),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.textPrimary,
        linearTrackColor: c.surfaceAlt,
        circularTrackColor: Colors.transparent,
        linearMinHeight: 3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? c.onPrimary
                : c.textSecondary),
        trackColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? c.primary : c.surfaceAlt),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? c.primary : c.borderStrong),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? c.primary
                : Colors.transparent),
        checkColor: WidgetStateProperty.resolveWith((_) => c.onPrimary),
        side: BorderSide(color: c.borderStrong, width: 1.5),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(6))),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected) ? c.primary : c.borderStrong),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.surfaceInverse,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: textTheme.labelSmall?.copyWith(color: c.textOnInverse),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shadowColor: c.shadow,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        textStyle: textTheme.bodyMedium,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.textPrimary,
        selectionColor: c.primary.withValues(alpha: 0.18),
        selectionHandleColor: c.primary,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: c.surfaceAlt,
          foregroundColor: c.textSecondary,
          selectedBackgroundColor: c.surface,
          selectedForegroundColor: c.textPrimary,
          side: BorderSide(color: c.border),
          textStyle: textTheme.labelLarge,
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.control),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: c.textPrimary,
        unselectedLabelColor: c.textTertiary,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        labelStyle: textTheme.labelLarge,
        unselectedLabelStyle:
            textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
      ),
    );

    return base;
  }

  // Geist type scale. Money styles live on [AppText] (tabular figures).
  static TextTheme _textTheme(AppColors c) {
    TextStyle s({
      required double size,
      required FontWeight weight,
      required double height,
      double letterSpacing = 0,
      Color? color,
    }) {
      return TextStyle(
        fontFamily: AppText.fontSans,
        fontFamilyFallback: AppText.fontFallback,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: letterSpacing,
        color: color ?? c.textPrimary,
      );
    }

    return TextTheme(
      // Hero numbers (net worth) and full-screen statements.
      displayLarge: s(
          size: 40, weight: FontWeight.w700, height: 1.1, letterSpacing: -1.0),
      displayMedium: s(
          size: 34, weight: FontWeight.w700, height: 1.12, letterSpacing: -0.8),
      displaySmall: s(
          size: 28, weight: FontWeight.w700, height: 1.15, letterSpacing: -0.6),
      // Screen titles.
      headlineLarge: s(
          size: 24, weight: FontWeight.w700, height: 1.2, letterSpacing: -0.4),
      headlineMedium: s(
          size: 20, weight: FontWeight.w600, height: 1.25, letterSpacing: -0.2),
      headlineSmall: s(
          size: 18, weight: FontWeight.w600, height: 1.3, letterSpacing: -0.1),
      // Cards, app bars, dialogs.
      titleLarge: s(
          size: 18, weight: FontWeight.w600, height: 1.3, letterSpacing: -0.1),
      titleMedium: s(size: 16, weight: FontWeight.w600, height: 1.35),
      titleSmall: s(
          size: 14, weight: FontWeight.w600, height: 1.4, letterSpacing: 0.05),
      // Body copy.
      bodyLarge: s(size: 16, weight: FontWeight.w400, height: 1.5),
      bodyMedium: s(size: 14, weight: FontWeight.w400, height: 1.45),
      bodySmall: s(size: 12, weight: FontWeight.w400, height: 1.4),
      // Buttons, chips, badges, group headers.
      labelLarge: s(
          size: 14, weight: FontWeight.w600, height: 1.3, letterSpacing: 0.05),
      labelMedium:
          s(size: 12, weight: FontWeight.w500, height: 1.3, letterSpacing: 0.1),
      labelSmall:
          s(size: 11, weight: FontWeight.w500, height: 1.3, letterSpacing: 0.3),
    );
  }
}
