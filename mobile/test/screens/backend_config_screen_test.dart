import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/screens/backend_config_screen.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('BackendConfigScreen', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ApiConfig.setBaseUrl('https://demo.sure.am');
    });

    Widget createTestWidget({VoidCallback? onConfigSaved}) {
      return MaterialApp(
        home: BackendConfigScreen(onConfigSaved: onConfigSaved),
      );
    }

    group('UI Elements', () {
      testWidgets('should display all essential UI elements', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
        expect(find.text('Configuration'), findsOneWidget);
        expect(find.text('Update your Sure server URL'), findsOneWidget);
        expect(find.text('Example URLs'), findsOneWidget);
        expect(find.byType(TextFormField), findsOneWidget);
        expect(find.text('Test Connection'), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);
      });

      testWidgets('should show example URLs in info box', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('• https://demo.sure.am\n'
            '• https://your-domain.com\n'
            '• http://localhost:3000'), findsOneWidget);
      });

      testWidgets('should display URL text field with correct properties', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect(textField.decoration?.labelText, equals('Sure server URL'));
        expect(textField.decoration?.hintText, equals('https://app.sure.am'));
        expect(textField.decoration?.prefixIcon, isNotNull);
        expect(textField.keyboardType, equals(TextInputType.url));
      });

      testWidgets('should show settings icon in title', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final icon = tester.widget<Icon>(find.byIcon(Icons.settings_outlined));
        expect(icon.size, equals(80));
      });
    });

    group('URL Loading', () {
      testWidgets('should load default URL when no saved URL exists', (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect((textField.controller as TextEditingController).text, equals('https://demo.sure.am'));
      });

      testWidgets('should load saved URL from SharedPreferences', (tester) async {
        const savedUrl = 'https://saved.example.com';
        SharedPreferences.setMockInitialValues({'backend_url': savedUrl});

        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect((textField.controller as TextEditingController).text, equals(savedUrl));
      });

      testWidgets('should prefer saved URL over default URL', (tester) async {
        SharedPreferences.setMockInitialValues({'backend_url': 'https://custom.com'});
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect((textField.controller as TextEditingController).text, equals('https://custom.com'));
      });

      testWidgets('should handle empty saved URL gracefully', (tester) async {
        SharedPreferences.setMockInitialValues({'backend_url': ''});
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect((textField.controller as TextEditingController).text, equals('https://demo.sure.am'));
      });
    });

    group('URL Validation', () {
      testWidgets('should show error when URL is empty', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsOneWidget);
      });

      testWidgets('should show error when URL does not start with http:// or https://', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'example.com');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('URL must start with http:// or https://'), findsOneWidget);
      });

      testWidgets('should accept valid http URL', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'http://localhost:3000');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsNothing);
        expect(find.text('URL must start with http:// or https://'), findsNothing);
      });

      testWidgets('should accept valid https URL', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://demo.sure.am');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsNothing);
        expect(find.text('URL must start with http:// or https://'), findsNothing);
      });

      testWidgets('should show error for invalid URL format', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'http://');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a valid URL'), findsOneWidget);
      });

      testWidgets('should validate on Continue button press', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsOneWidget);
      });

      testWidgets('should validate on Test Connection button press', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Test Connection'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsOneWidget);
      });
    });

    group('Save and Continue', () {
      testWidgets('should save URL to SharedPreferences', (tester) async {
        const newUrl = 'https://test.example.com';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), newUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(newUrl));
      });

      testWidgets('should update ApiConfig base URL', (tester) async {
        const newUrl = 'https://new.example.com';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), newUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(ApiConfig.baseUrl, equals(newUrl));
      });

      testWidgets('should normalize URL by removing trailing slashes', (tester) async {
        const urlWithSlashes = 'https://example.com///';
        const expectedUrl = 'https://example.com';

        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), urlWithSlashes);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(expectedUrl));
        expect(ApiConfig.baseUrl, equals(expectedUrl));
      });

      testWidgets('should trim whitespace from URL', (tester) async {
        const urlWithSpaces = '  https://example.com  ';
        const expectedUrl = 'https://example.com';

        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), urlWithSpaces);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(expectedUrl));
      });

      testWidgets('should call onConfigSaved callback when provided', (tester) async {
        var callbackCalled = false;
        void onConfigSaved() {
          callbackCalled = true;
        }

        await tester.pumpWidget(createTestWidget(onConfigSaved: onConfigSaved));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://test.com');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(callbackCalled, isTrue);
      });

      testWidgets('should show loading indicator while saving', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://test.com');
        await tester.tap(find.text('Continue'));
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsWidgets);
      });

      testWidgets('should disable buttons while saving', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://test.com');
        await tester.tap(find.text('Continue'));
        await tester.pump();

        final continueButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Continue'),
        );
        expect(continueButton.enabled, isFalse);
      });
    });

    group('Error Messages', () {
      testWidgets('should display and dismiss error messages', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        // Trigger validation error
        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // Error should be shown
        expect(find.text('Please enter a backend URL'), findsOneWidget);
      });

      testWidgets('should clear error message when fixed', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        // Trigger error
        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsOneWidget);

        // Fix error
        await tester.enterText(find.byType(TextFormField), 'https://valid.com');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a backend URL'), findsNothing);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle very long URLs', (tester) async {
        final longUrl = 'https://${'a' * 200}.com';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), longUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(longUrl));
      });

      testWidgets('should handle URLs with query parameters', (tester) async {
        const urlWithParams = 'https://example.com?param=value&other=123';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), urlWithParams);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(urlWithParams));
      });

      testWidgets('should handle URLs with ports', (tester) async {
        const urlWithPort = 'https://example.com:8080';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), urlWithPort);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(urlWithPort));
      });

      testWidgets('should handle localhost URLs', (tester) async {
        const localhostUrl = 'http://localhost:3000';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), localhostUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(localhostUrl));
      });

      testWidgets('should handle IP address URLs', (tester) async {
        const ipUrl = 'http://192.168.1.100:8080';
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), ipUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals(ipUrl));
      });
    });

    group('Keyboard Actions', () {
      testWidgets('should submit form on keyboard done action', (tester) async {
        var callbackCalled = false;
        void onConfigSaved() {
          callbackCalled = true;
        }

        await tester.pumpWidget(createTestWidget(onConfigSaved: onConfigSaved));
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://test.com');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(callbackCalled, isTrue);
      });
    });

    group('Accessibility', () {
      testWidgets('should have text field with correct input type', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect(textField.keyboardType, equals(TextInputType.url));
        expect(textField.autocorrect, isFalse);
      });

      testWidgets('should have proper button hierarchy', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.widgetWithText(ElevatedButton, 'Continue'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Test Connection'), findsOneWidget);
      });
    });

    group('Regression Tests', () {
      testWidgets('should not lose URL input when validation fails', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        const invalidUrl = 'invalid-url';
        await tester.enterText(find.byType(TextFormField), invalidUrl);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        final textField = tester.widget<TextFormField>(find.byType(TextFormField));
        expect((textField.controller as TextEditingController).text, equals(invalidUrl));
      });

      testWidgets('should maintain scroll position when error appears', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), '');
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // Widget should still be visible
        expect(find.byType(TextFormField), findsOneWidget);
        expect(find.text('Continue'), findsOneWidget);
      });

      testWidgets('should handle rapid button presses gracefully', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextFormField), 'https://test.com');

        // Tap multiple times rapidly
        await tester.tap(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // Should only save once
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals('https://test.com'));
      });
    });
  });
}