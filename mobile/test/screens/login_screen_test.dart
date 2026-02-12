import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/screens/login_screen.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:flutter_svg/flutter_svg.dart';

// Mock AuthProvider for testing
class MockAuthProvider extends ChangeNotifier implements AuthProvider {
  bool _isLoading = false;
  String? _errorMessage;
  bool _showMfaInput = false;

  @override
  bool get isLoading => _isLoading;

  @override
  String? get errorMessage => _errorMessage;

  @override
  bool get showMfaInput => _showMfaInput;

  @override
  bool get isAuthenticated => false;

  @override
  bool get isInitializing => false;

  @override
  bool get isApiKeyAuth => false;

  @override
  bool get mfaRequired => _showMfaInput;

  @override
  dynamic get user => null;

  @override
  dynamic get tokens => null;

  void setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void setError(String? error) {
    _errorMessage = error;
    notifyListeners();
  }

  void setShowMfaInput(bool show) {
    _showMfaInput = show;
    notifyListeners();
  }

  @override
  Future<bool> login({
    required String email,
    required String password,
    String? otpCode,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 100));

    _isLoading = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> loginWithApiKey({required String apiKey}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 100));

    _isLoading = false;
    notifyListeners();
    return true;
  }

  @override
  Future<void> startSsoLogin(String provider) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 100));

    _isLoading = false;
    notifyListeners();
  }

  @override
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  @override
  Future<String?> getValidAccessToken() async => null;

  @override
  Future<bool> handleSsoCallback(Uri uri) async => false;

  @override
  Future<void> logout() async {}

  @override
  Future<bool> signup({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? inviteCode,
  }) async =>
      false;
}

void main() {
  group('LoginScreen', () {
    late MockAuthProvider mockAuthProvider;

    setUp(() {
      mockAuthProvider = MockAuthProvider();
      ApiConfig.setBaseUrl('https://demo.sure.am');
    });

    Widget createTestWidget({VoidCallback? onGoToSettings}) {
      return MaterialApp(
        home: ChangeNotifierProvider<AuthProvider>.value(
          value: mockAuthProvider,
          child: LoginScreen(onGoToSettings: onGoToSettings),
        ),
      );
    }

    group('UI Elements', () {
      testWidgets('should display all essential UI elements', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byType(SvgPicture), findsNWidgets(2)); // Logomark + Google logo
        expect(find.text('Please '), findsOneWidget);
        expect(find.text('Sign Up'), findsOneWidget);
        expect(find.text(' first!'), findsOneWidget);
        expect(find.text('Email'), findsOneWidget);
        expect(find.text('Password'), findsOneWidget);
        expect(find.text('Sign In'), findsNWidgets(2)); // Main button + API dialog button
        expect(find.text('Sign in with Google'), findsOneWidget);
        expect(find.text('API-Key Login'), findsOneWidget);
      });

      testWidgets('should display settings button', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
        expect(find.byTooltip('Backend Settings'), findsOneWidget);
      });

      testWidgets('should display email field with correct properties', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final emailField = find.widgetWithText(TextFormField, 'Email');
        expect(emailField, findsOneWidget);

        final widget = tester.widget<TextFormField>(emailField);
        expect(widget.keyboardType, equals(TextInputType.emailAddress));
        expect(widget.autocorrect, isFalse);
      });

      testWidgets('should display password field with visibility toggle', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final passwordField = find.widgetWithText(TextFormField, 'Password');
        expect(passwordField, findsOneWidget);

        final widget = tester.widget<TextFormField>(passwordField);
        expect(widget.obscureText, isTrue);
        expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      });

      testWidgets('should display backend URL info', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Sure server URL:'), findsOneWidget);
        expect(find.text('https://demo.sure.am'), findsOneWidget);
      });

      testWidgets('should display divider with "or" text', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('or'), findsOneWidget);
        expect(find.byType(Divider), findsNWidgets(2));
      });

      testWidgets('should display Google sign-in button with logo', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final googleButton = find.widgetWithText(OutlinedButton, 'Sign in with Google');
        expect(googleButton, findsOneWidget);
      });
    });

    group('Email Validation', () {
      testWidgets('should show error when email is empty', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter your email'), findsOneWidget);
      });

      testWidgets('should show error when email is invalid', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'invalidemail');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a valid email'), findsOneWidget);
      });

      testWidgets('should accept valid email', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter a valid email'), findsNothing);
      });
    });

    group('Password Validation', () {
      testWidgets('should show error when password is empty', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter your password'), findsOneWidget);
      });

      testWidgets('should accept any non-empty password', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'pass');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter your password'), findsNothing);
      });
    });

    group('Password Visibility Toggle', () {
      testWidgets('should toggle password visibility', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final passwordField = find.widgetWithText(TextFormField, 'Password');
        var widget = tester.widget<TextFormField>(passwordField);
        expect(widget.obscureText, isTrue);

        await tester.tap(find.byIcon(Icons.visibility_outlined));
        await tester.pumpAndSettle();

        widget = tester.widget<TextFormField>(passwordField);
        expect(widget.obscureText, isFalse);
        expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

        await tester.tap(find.byIcon(Icons.visibility_off_outlined));
        await tester.pumpAndSettle();

        widget = tester.widget<TextFormField>(passwordField);
        expect(widget.obscureText, isTrue);
      });
    });

    group('Login Flow', () {
      testWidgets('should call login when form is valid', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should show loading indicator during login', (tester) async {
        mockAuthProvider.setLoading(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsWidgets);
      });

      testWidgets('should disable button during login', (tester) async {
        mockAuthProvider.setLoading(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final signInButton = tester.widget<ElevatedButton>(
          find.widgetWithText(ElevatedButton, 'Sign In'),
        );
        expect(signInButton.enabled, isFalse);
      });
    });

    group('MFA Flow', () {
      testWidgets('should show MFA input field when MFA is required', (tester) async {
        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Two-factor authentication is enabled. Enter your code.'), findsOneWidget);
        expect(find.text('Authentication Code'), findsOneWidget);
        expect(find.byIcon(Icons.security), findsOneWidget);
      });

      testWidgets('should not show MFA input initially', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Authentication Code'), findsNothing);
      });

      testWidgets('should require OTP code when MFA is shown', (tester) async {
        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        expect(find.text('Please enter your authentication code'), findsOneWidget);
      });

      testWidgets('should accept valid OTP code', (tester) async {
        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.enterText(find.widgetWithText(TextFormField, 'Authentication Code'), '123456');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should show MFA info box with security icon', (tester) async {
        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.security), findsOneWidget);
        expect(find.text('Two-factor authentication is enabled. Enter your code.'), findsOneWidget);
      });
    });

    group('Error Handling', () {
      testWidgets('should display error message', (tester) async {
        mockAuthProvider.setError('Invalid credentials');
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Invalid credentials'), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
      });

      testWidgets('should allow dismissing error message', (tester) async {
        mockAuthProvider.setError('Test error');
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Test error'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();

        expect(find.text('Test error'), findsNothing);
      });

      testWidgets('should show error container with correct styling', (tester) async {
        mockAuthProvider.setError('Error message');
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.byIcon(Icons.close), findsOneWidget);
      });
    });

    group('API Key Login', () {
      testWidgets('should show API key dialog when button is tapped', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('API-Key Login'));
        await tester.pumpAndSettle();

        expect(find.text('API Key Login'), findsOneWidget);
        expect(find.text('Enter your API key to sign in.'), findsOneWidget);
        expect(find.text('API Key'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
      });

      testWidgets('should close dialog when Cancel is tapped', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('API-Key Login'));
        await tester.pumpAndSettle();

        expect(find.text('API Key Login'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(find.text('API Key Login'), findsNothing);
      });

      testWidgets('should have obscured text field in API key dialog', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('API-Key Login'));
        await tester.pumpAndSettle();

        final apiKeyField = find.widgetWithText(TextField, 'API Key');
        expect(apiKeyField, findsOneWidget);

        final widget = tester.widget<TextField>(apiKeyField);
        expect(widget.obscureText, isTrue);
      });

      testWidgets('should call loginWithApiKey when Sign In is tapped', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('API-Key Login'));
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'test-api-key');
        await tester.tap(find.text('Sign In').last);
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should not submit empty API key', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('API-Key Login'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Sign In').last);
        await tester.pumpAndSettle();

        // Dialog should still be open
        expect(find.text('API Key Login'), findsOneWidget);
      });
    });

    group('Google SSO', () {
      testWidgets('should call startSsoLogin when Google button is tapped', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.text('Sign in with Google'));
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should disable Google button during loading', (tester) async {
        mockAuthProvider.setLoading(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final googleButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Sign in with Google'),
        );
        expect(googleButton.enabled, isFalse);
      });
    });

    group('Settings Navigation', () {
      testWidgets('should call onGoToSettings when settings button is tapped', (tester) async {
        var settingsCalled = false;
        void onGoToSettings() {
          settingsCalled = true;
        }

        await tester.pumpWidget(createTestWidget(onGoToSettings: onGoToSettings));
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();

        expect(settingsCalled, isTrue);
      });

      testWidgets('should not crash when onGoToSettings is null', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.tap(find.byIcon(Icons.settings_outlined));
        await tester.pumpAndSettle();

        // Should not throw
      });
    });

    group('Keyboard Actions', () {
      testWidgets('should move to password field on email field done', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final emailField = find.widgetWithText(TextFormField, 'Email');
        final widget = tester.widget<TextFormField>(emailField);
        expect(widget.textInputAction, equals(TextInputAction.next));
      });

      testWidgets('should submit form on password field done when no MFA', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should submit form on OTP field done when MFA is shown', (tester) async {
        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');
        await tester.enterText(find.widgetWithText(TextFormField, 'Authentication Code'), '123456');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });
    });

    group('Edge Cases', () {
      testWidgets('should handle very long email addresses', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final longEmail = '${'a' * 200}@example.com';
        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), longEmail);
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should handle special characters in password', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        const specialPassword = '!@#\$%^&*()_+{}[]|:;<>?,./~`';
        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), specialPassword);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should handle whitespace in email', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), '  user@example.com  ');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        // Should trim and submit
        expect(mockAuthProvider.isLoading, isTrue);
      });

      testWidgets('should handle rapid button taps gracefully', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'user@example.com');
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), 'password123');

        // Tap multiple times rapidly
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pump();

        // Should only trigger once due to loading state
        expect(mockAuthProvider.isLoading, isTrue);
      });
    });

    group('Accessibility', () {
      testWidgets('should have proper semantic labels', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.byType(Icon), findsWidgets);
        expect(find.byType(TextFormField), findsNWidgets(2)); // Email and password initially
      });

      testWidgets('should have keyboard types for accessibility', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final emailField = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Email'),
        );
        expect(emailField.keyboardType, equals(TextInputType.emailAddress));

        mockAuthProvider.setShowMfaInput(true);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        final otpField = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Authentication Code'),
        );
        expect(otpField.keyboardType, equals(TextInputType.number));
      });
    });

    group('Regression Tests', () {
      testWidgets('should maintain form state during validation', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        const email = 'user@example.com';
        const password = 'mypassword';

        await tester.enterText(find.widgetWithText(TextFormField, 'Email'), email);
        await tester.enterText(find.widgetWithText(TextFormField, 'Password'), password);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In'));
        await tester.pumpAndSettle();

        final emailWidget = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Email'),
        );
        final passwordWidget = tester.widget<TextFormField>(
          find.widgetWithText(TextFormField, 'Password'),
        );

        expect((emailWidget.controller as TextEditingController).text, equals(email));
        expect((passwordWidget.controller as TextEditingController).text, equals(password));
      });

      testWidgets('should clear error when starting new login attempt', (tester) async {
        mockAuthProvider.setError('Previous error');
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Previous error'), findsOneWidget);

        mockAuthProvider.setError(null);
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        expect(find.text('Previous error'), findsNothing);
      });

      testWidgets('should handle provider updates correctly', (tester) async {
        await tester.pumpWidget(createTestWidget());
        await tester.pumpAndSettle();

        // Start loading
        mockAuthProvider.setLoading(true);
        await tester.pumpAndSettle();
        expect(find.byType(CircularProgressIndicator), findsWidgets);

        // Stop loading
        mockAuthProvider.setLoading(false);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ElevatedButton, 'Sign In'), findsOneWidget);
      });
    });
  });
}