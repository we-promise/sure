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
    expect(theme.colorScheme.secondary, SureTokens.light.info);
    expect(theme.colorScheme.surface, SureTokens.light.surface);
    expect(theme.colorScheme.onSurface, SureTokens.light.textPrimary);
    expect(theme.colorScheme.error, SureTokens.light.destructive);
    expect(theme.scaffoldBackgroundColor, SureTokens.light.surface);
    expect(theme.cardTheme.color, SureTokens.light.container);
  });

  test('dark theme uses Sure token values', () {
    final theme = SureTheme.dark;

    expect(theme.brightness, Brightness.dark);
    expect(theme.textTheme.bodyMedium?.fontFamily, SureTokens.fontSans);
    expect(theme.colorScheme.primary, SureTokens.dark.link);
    expect(theme.colorScheme.secondary, SureTokens.dark.info);
    expect(theme.colorScheme.surface, SureTokens.dark.surface);
    expect(theme.colorScheme.onSurface, SureTokens.dark.textPrimary);
    expect(theme.colorScheme.error, SureTokens.dark.destructive);
    expect(theme.scaffoldBackgroundColor, SureTokens.dark.surface);
    expect(theme.cardTheme.color, SureTokens.dark.container);
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
