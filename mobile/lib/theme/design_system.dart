import 'package:flutter/material.dart';

/// Design system tokens matching the Rails/Tailwind design system.
///
/// This mirrors the color palette and semantic tokens defined in:
/// - `app/assets/tailwind/maybe-design-system.css`
/// - `app/assets/tailwind/maybe-design-system/*.css`
///
/// Usage:
/// ```dart
/// Container(
///   color: SureColors.surface(context),
///   child: Text('Hello', style: TextStyle(color: SureColors.textPrimary(context))),
/// )
/// ```
class SureColors {
  SureColors._();

  // ==========================================================================
  // Base Colors (from maybe-design-system.css)
  // ==========================================================================

  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF0B0B0B);

  // --------------------------------------------------------------------------
  // Gray Scale
  // --------------------------------------------------------------------------
  static const Color gray25 = Color(0xFFFAFAFA);
  static const Color gray50 = Color(0xFFF7F7F7);
  static const Color gray100 = Color(0xFFF0F0F0);
  static const Color gray200 = Color(0xFFE7E7E7);
  static const Color gray300 = Color(0xFFCFCFCF);
  static const Color gray400 = Color(0xFF9E9E9E);
  static const Color gray500 = Color(0xFF737373);
  static const Color gray600 = Color(0xFF5C5C5C);
  static const Color gray700 = Color(0xFF363636);
  static const Color gray800 = Color(0xFF242424);
  static const Color gray900 = Color(0xFF171717);

  // --------------------------------------------------------------------------
  // Red Scale
  // --------------------------------------------------------------------------
  static const Color red25 = Color(0xFFFFFBFB);
  static const Color red50 = Color(0xFFFFF1F0);
  static const Color red100 = Color(0xFFFFDEDB);
  static const Color red200 = Color(0xFFFEB9B3);
  static const Color red300 = Color(0xFFF88C86);
  static const Color red400 = Color(0xFFED4E4E);
  static const Color red500 = Color(0xFFF13636);
  static const Color red600 = Color(0xFFEC2222);
  static const Color red700 = Color(0xFFC91313);
  static const Color red800 = Color(0xFFA40E0E);
  static const Color red900 = Color(0xFF7E0707);

  // --------------------------------------------------------------------------
  // Green Scale
  // --------------------------------------------------------------------------
  static const Color green25 = Color(0xFFF6FEF9);
  static const Color green50 = Color(0xFFECFDF3);
  static const Color green100 = Color(0xFFD1FADF);
  static const Color green200 = Color(0xFFA6F4C5);
  static const Color green300 = Color(0xFF6CE9A6);
  static const Color green400 = Color(0xFF32D583);
  static const Color green500 = Color(0xFF12B76A);
  static const Color green600 = Color(0xFF10A861);
  static const Color green700 = Color(0xFF078C52);
  static const Color green800 = Color(0xFF05603A);
  static const Color green900 = Color(0xFF054F31);

  // --------------------------------------------------------------------------
  // Yellow Scale
  // --------------------------------------------------------------------------
  static const Color yellow25 = Color(0xFFFFFCF5);
  static const Color yellow50 = Color(0xFFFFFAEB);
  static const Color yellow100 = Color(0xFFFEF0C7);
  static const Color yellow200 = Color(0xFFFEDF89);
  static const Color yellow300 = Color(0xFFFEC84B);
  static const Color yellow400 = Color(0xFFFDB022);
  static const Color yellow500 = Color(0xFFF79009);
  static const Color yellow600 = Color(0xFFDC6803);
  static const Color yellow700 = Color(0xFFB54708);
  static const Color yellow800 = Color(0xFF93370D);
  static const Color yellow900 = Color(0xFF7A2E0E);

  // --------------------------------------------------------------------------
  // Cyan Scale
  // --------------------------------------------------------------------------
  static const Color cyan25 = Color(0xFFF5FEFF);
  static const Color cyan50 = Color(0xFFECFDFF);
  static const Color cyan100 = Color(0xFFCFF9FE);
  static const Color cyan200 = Color(0xFFA5F0FC);
  static const Color cyan300 = Color(0xFF67E3F9);
  static const Color cyan400 = Color(0xFF22CCEE);
  static const Color cyan500 = Color(0xFF06AED4);
  static const Color cyan600 = Color(0xFF088AB2);
  static const Color cyan700 = Color(0xFF0E7090);
  static const Color cyan800 = Color(0xFF155B75);
  static const Color cyan900 = Color(0xFF155B75);

  // --------------------------------------------------------------------------
  // Blue Scale
  // --------------------------------------------------------------------------
  static const Color blue25 = Color(0xFFF5FAFF);
  static const Color blue50 = Color(0xFFEFF8FF);
  static const Color blue100 = Color(0xFFD1E9FF);
  static const Color blue200 = Color(0xFFB2DDFF);
  static const Color blue300 = Color(0xFF84CAFF);
  static const Color blue400 = Color(0xFF53B1FD);
  static const Color blue500 = Color(0xFF2E90FA);
  static const Color blue600 = Color(0xFF1570EF);
  static const Color blue700 = Color(0xFF175CD3);
  static const Color blue800 = Color(0xFF1849A9);
  static const Color blue900 = Color(0xFF194185);

  // --------------------------------------------------------------------------
  // Indigo Scale (Primary brand color)
  // --------------------------------------------------------------------------
  static const Color indigo25 = Color(0xFFF5F8FF);
  static const Color indigo50 = Color(0xFFEFF4FF);
  static const Color indigo100 = Color(0xFFE0EAFF);
  static const Color indigo200 = Color(0xFFC7D7FE);
  static const Color indigo300 = Color(0xFFA4BCFD);
  static const Color indigo400 = Color(0xFF8098F9);
  static const Color indigo500 = Color(0xFF6172F3);
  static const Color indigo600 = Color(0xFF444CE7);
  static const Color indigo700 = Color(0xFF3538CD);
  static const Color indigo800 = Color(0xFF2D31A6);
  static const Color indigo900 = Color(0xFF2D3282);

  // --------------------------------------------------------------------------
  // Violet Scale
  // --------------------------------------------------------------------------
  static const Color violet25 = Color(0xFFFBFAFF);
  static const Color violet50 = Color(0xFFF5F3FF);
  static const Color violet100 = Color(0xFFECE9FE);
  static const Color violet200 = Color(0xFFDDD6FE);
  static const Color violet300 = Color(0xFFC3B5FD);
  static const Color violet400 = Color(0xFFA48AFB);
  static const Color violet500 = Color(0xFF875BF7);
  static const Color violet600 = Color(0xFF7839EE);
  static const Color violet700 = Color(0xFF6927DA);

  // --------------------------------------------------------------------------
  // Fuchsia Scale
  // --------------------------------------------------------------------------
  static const Color fuchsia25 = Color(0xFFFEFAFF);
  static const Color fuchsia50 = Color(0xFFFDF4FF);
  static const Color fuchsia100 = Color(0xFFFBE8FF);
  static const Color fuchsia200 = Color(0xFFF6D0FE);
  static const Color fuchsia300 = Color(0xFFEEAAFD);
  static const Color fuchsia400 = Color(0xFFE478FA);
  static const Color fuchsia500 = Color(0xFFD444F1);
  static const Color fuchsia600 = Color(0xFFBA24D5);
  static const Color fuchsia700 = Color(0xFF9F1AB1);
  static const Color fuchsia800 = Color(0xFF821890);
  static const Color fuchsia900 = Color(0xFF6F1877);

  // --------------------------------------------------------------------------
  // Pink Scale
  // --------------------------------------------------------------------------
  static const Color pink25 = Color(0xFFFFFAFC);
  static const Color pink50 = Color(0xFFFEF0F7);
  static const Color pink100 = Color(0xFFFFD1E2);
  static const Color pink200 = Color(0xFFFFB1CE);
  static const Color pink300 = Color(0xFFFD8FBA);
  static const Color pink400 = Color(0xFFF86BA7);
  static const Color pink500 = Color(0xFFF23E94);
  static const Color pink600 = Color(0xFFD5327F);
  static const Color pink700 = Color(0xFFBA256B);
  static const Color pink800 = Color(0xFF9E1958);
  static const Color pink900 = Color(0xFF840B45);

  // --------------------------------------------------------------------------
  // Orange Scale
  // --------------------------------------------------------------------------
  static const Color orange25 = Color(0xFFFFF9F5);
  static const Color orange50 = Color(0xFFFFF4ED);
  static const Color orange100 = Color(0xFFFFE6D5);
  static const Color orange200 = Color(0xFFFFD6AE);
  static const Color orange300 = Color(0xFFFF9C66);
  static const Color orange400 = Color(0xFFFF692E);
  static const Color orange500 = Color(0xFFFF4405);
  static const Color orange600 = Color(0xFFE62E05);
  static const Color orange700 = Color(0xFFBC1B06);
  static const Color orange800 = Color(0xFF97180C);
  static const Color orange900 = Color(0xFF771A0D);

  // ==========================================================================
  // Semantic Colors (context-aware, from *-utils.css)
  // ==========================================================================

  /// Returns true if the current theme is dark mode.
  static bool isDarkMode(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark;
  }

  // --------------------------------------------------------------------------
  // Background Semantic Colors (from background-utils.css)
  // --------------------------------------------------------------------------

  /// bg-surface: Main page background
  static Color surface(BuildContext context) =>
      isDarkMode(context) ? black : gray50;

  /// bg-surface-hover: Hovered surface
  static Color surfaceHover(BuildContext context) =>
      isDarkMode(context) ? gray900 : gray100;

  /// bg-surface-inset: Inset surface areas
  static Color surfaceInset(BuildContext context) =>
      isDarkMode(context) ? gray800 : gray100;

  /// bg-container: Card/container background
  static Color container(BuildContext context) =>
      isDarkMode(context) ? gray900 : white;

  /// bg-container-hover: Hovered container
  static Color containerHover(BuildContext context) =>
      isDarkMode(context) ? gray800 : gray50;

  /// bg-container-inset: Inset container areas
  static Color containerInset(BuildContext context) =>
      isDarkMode(context) ? gray800 : gray50;

  /// bg-inverse: Inverted background
  static Color inverse(BuildContext context) =>
      isDarkMode(context) ? white : gray800;

  /// bg-overlay: Modal/overlay background
  static Color overlay(BuildContext context) =>
      isDarkMode(context) ? black.withValues(alpha: 0.85) : gray100.withValues(alpha: 0.5);

  // --------------------------------------------------------------------------
  // Text Semantic Colors (from text-utils.css)
  // --------------------------------------------------------------------------

  /// text-primary: Primary text color
  static Color textPrimary(BuildContext context) =>
      isDarkMode(context) ? white : gray900;

  /// text-inverse: Inverted text color
  static Color textInverse(BuildContext context) =>
      isDarkMode(context) ? gray900 : white;

  /// text-secondary: Secondary/muted text
  static Color textSecondary(BuildContext context) =>
      isDarkMode(context) ? gray300 : gray500;

  /// text-subdued: Very muted text
  static Color textSubdued(BuildContext context) =>
      isDarkMode(context) ? gray500 : gray400;

  /// text-link: Link text color
  static Color textLink(BuildContext context) =>
      isDarkMode(context) ? blue500 : blue600;

  // --------------------------------------------------------------------------
  // Foreground Semantic Colors (from foreground-utils.css)
  // --------------------------------------------------------------------------

  /// fg-primary: Primary foreground
  static Color fgPrimary(BuildContext context) =>
      isDarkMode(context) ? white : gray900;

  /// fg-secondary: Secondary foreground
  static Color fgSecondary(BuildContext context) =>
      isDarkMode(context) ? gray400 : gray50;

  /// fg-subdued: Subdued foreground
  static Color fgSubdued(BuildContext context) =>
      isDarkMode(context) ? gray500 : gray400;

  /// fg-inverse: Inverted foreground
  static Color fgInverse(BuildContext context) =>
      isDarkMode(context) ? gray900 : white;

  // --------------------------------------------------------------------------
  // Status Colors
  // --------------------------------------------------------------------------

  /// Success color (light: green600, dark: green500)
  static Color success(BuildContext context) =>
      isDarkMode(context) ? green500 : green600;

  /// Warning color (light: yellow600, dark: yellow400)
  static Color warning(BuildContext context) =>
      isDarkMode(context) ? yellow400 : yellow600;

  /// Destructive/error color (light: red600, dark: red400)
  static Color destructive(BuildContext context) =>
      isDarkMode(context) ? red400 : red600;

  // --------------------------------------------------------------------------
  // Border Colors
  // --------------------------------------------------------------------------

  /// Primary border color
  static Color borderPrimary(BuildContext context) =>
      isDarkMode(context) ? gray700 : gray200;

  /// Secondary border color
  static Color borderSecondary(BuildContext context) =>
      isDarkMode(context) ? gray800 : gray100;
}

/// Typography configuration matching the Rails design system.
///
/// Uses the Geist font family as defined in maybe-design-system.css:
/// ```css
/// --font-sans: 'Geist', system-ui, ...
/// --font-mono: 'Geist Mono', ui-monospace, ...
/// ```
class SureTypography {
  SureTypography._();

  /// Sans-serif font family (matches --font-sans)
  static const String fontFamilySans = 'Geist';

  /// Monospace font family (matches --font-mono)
  static const String fontFamilyMono = 'Geist Mono';

  /// Fallback sans-serif fonts
  static const List<String> fontFamilySansFallback = [
    'system-ui',
    '-apple-system',
    'BlinkMacSystemFont',
    'Segoe UI',
    'Roboto',
    'Helvetica Neue',
    'Arial',
    'sans-serif',
  ];

  /// Fallback monospace fonts
  static const List<String> fontFamilyMonoFallback = [
    'ui-monospace',
    'SFMono-Regular',
    'Menlo',
    'Monaco',
    'Consolas',
    'monospace',
  ];
}

/// Border radius values matching the Rails design system.
class SureBorderRadius {
  SureBorderRadius._();

  static const double xs = 4.0;
  static const double sm = 6.0;
  static const double md = 8.0;  // --border-radius-md
  static const double lg = 10.0; // --border-radius-lg
  static const double xl = 12.0;
  static const double xxl = 16.0;
  static const double full = 9999.0;
}

/// Shadow values matching the Rails design system.
class SureShadows {
  SureShadows._();

  /// shadow-xs
  static List<BoxShadow> xs(BuildContext context) => [
    BoxShadow(
      offset: const Offset(0, 1),
      blurRadius: 2,
      color: SureColors.isDarkMode(context)
          ? SureColors.white.withValues(alpha: 0.08)
          : SureColors.black.withValues(alpha: 0.06),
    ),
  ];

  /// shadow-sm
  static List<BoxShadow> sm(BuildContext context) => [
    BoxShadow(
      offset: const Offset(0, 1),
      blurRadius: 6,
      color: SureColors.isDarkMode(context)
          ? SureColors.white.withValues(alpha: 0.08)
          : SureColors.black.withValues(alpha: 0.06),
    ),
  ];

  /// shadow-md
  static List<BoxShadow> md(BuildContext context) => [
    BoxShadow(
      offset: const Offset(0, 4),
      blurRadius: 8,
      spreadRadius: -2,
      color: SureColors.isDarkMode(context)
          ? SureColors.white.withValues(alpha: 0.08)
          : SureColors.black.withValues(alpha: 0.06),
    ),
  ];

  /// shadow-lg
  static List<BoxShadow> lg(BuildContext context) => [
    BoxShadow(
      offset: const Offset(0, 12),
      blurRadius: 16,
      spreadRadius: -4,
      color: SureColors.isDarkMode(context)
          ? SureColors.white.withValues(alpha: 0.08)
          : SureColors.black.withValues(alpha: 0.06),
    ),
  ];

  /// shadow-xl
  static List<BoxShadow> xl(BuildContext context) => [
    BoxShadow(
      offset: const Offset(0, 20),
      blurRadius: 24,
      spreadRadius: -4,
      color: SureColors.isDarkMode(context)
          ? SureColors.white.withValues(alpha: 0.08)
          : SureColors.black.withValues(alpha: 0.06),
    ),
  ];
}
