import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/main.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';

void main() {
  test('light theme uses Sure token values', () {
    final theme = SureTheme.light;

    expect(theme.brightness, Brightness.light);
    expect(theme.textTheme.bodyMedium?.fontFamily, SureTokens.fontSans);
    expect(theme.colorScheme.primary, SureTokens.light.link);
    expect(theme.colorScheme.onPrimary, SureTokens.light.textInverse);
    expect(theme.colorScheme.primaryContainer, SureTokens.light.surfaceInset);
    expect(theme.colorScheme.onPrimaryContainer, SureTokens.light.textPrimary);
    expect(theme.colorScheme.secondary, SureTokens.light.info);
    expect(theme.colorScheme.onSecondary, SureTokens.light.textInverse);
    expect(theme.colorScheme.secondaryContainer, SureTokens.light.surfaceInset);
    expect(
        theme.colorScheme.onSecondaryContainer, SureTokens.light.textPrimary);
    expect(theme.colorScheme.surface, SureTokens.light.surface);
    expect(theme.colorScheme.onSurface, SureTokens.light.textPrimary);
    expect(theme.colorScheme.error, SureTokens.light.destructive);
    expect(
        theme.colorScheme.errorContainer, SureTokens.light.destructiveSubtle);
    expect(theme.colorScheme.onErrorContainer, SureTokens.light.textPrimary);
    expect(theme.scaffoldBackgroundColor, SureTokens.light.surface);
    expect(theme.cardTheme.color, SureTokens.light.container);
    expect(theme.floatingActionButtonTheme.backgroundColor,
        SureTokens.light.buttonPrimary);
    expect(theme.floatingActionButtonTheme.foregroundColor,
        SureTokens.light.textInverse);
    expect(
      theme.elevatedButtonTheme.style?.minimumSize?.resolve({}),
      const Size(double.infinity, 50),
    );
  });

  test('dark theme uses Sure token values', () {
    final theme = SureTheme.dark;

    expect(theme.brightness, Brightness.dark);
    expect(theme.textTheme.bodyMedium?.fontFamily, SureTokens.fontSans);
    expect(theme.colorScheme.primary, SureTokens.dark.link);
    expect(theme.colorScheme.onPrimary, SureTokens.dark.textInverse);
    expect(theme.colorScheme.primaryContainer, SureTokens.dark.surfaceInset);
    expect(theme.colorScheme.onPrimaryContainer, SureTokens.dark.textPrimary);
    expect(theme.colorScheme.secondary, SureTokens.dark.info);
    expect(theme.colorScheme.onSecondary, SureTokens.dark.textInverse);
    expect(theme.colorScheme.secondaryContainer, SureTokens.dark.surfaceInset);
    expect(theme.colorScheme.onSecondaryContainer, SureTokens.dark.textPrimary);
    expect(theme.colorScheme.surface, SureTokens.dark.surface);
    expect(theme.colorScheme.onSurface, SureTokens.dark.textPrimary);
    expect(theme.colorScheme.error, SureTokens.dark.destructive);
    expect(theme.colorScheme.errorContainer, SureTokens.dark.destructiveSubtle);
    expect(theme.colorScheme.onErrorContainer, SureTokens.dark.textPrimary);
    expect(theme.scaffoldBackgroundColor, SureTokens.dark.surface);
    expect(theme.cardTheme.color, SureTokens.dark.container);
    expect(theme.floatingActionButtonTheme.backgroundColor,
        SureTokens.dark.buttonPrimary);
    expect(theme.floatingActionButtonTheme.foregroundColor,
        SureTokens.dark.textInverse);
    expect(
      theme.elevatedButtonTheme.style?.minimumSize?.resolve({}),
      const Size(double.infinity, 50),
    );
  });

  testWidgets('app wires Sure light and dark themes', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const SureApp());

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.theme?.colorScheme.surface, SureTokens.light.surface);
    expect(materialApp.darkTheme?.colorScheme.surface, SureTokens.dark.surface);
    expect(materialApp.themeMode, ThemeMode.system);
  });
}
