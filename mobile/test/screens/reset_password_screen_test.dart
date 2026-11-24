import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/screens/reset_password_screen.dart';
import 'package:sure_mobile/services/auth_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

class _FakeAuthService extends AuthService {
  _FakeAuthService(this.result);

  final Map<String, dynamic> result;

  @override
  Future<Map<String, dynamic>> resetPassword({
    required String token,
    required String password,
    required String passwordConfirmation,
  }) async {
    return result;
  }
}

class _FakeAuthProvider extends AuthProvider {
  bool logoutCalled = false;

  @override
  bool get isAuthenticated => false;

  @override
  Future<void> logout() async {
    logoutCalled = true;
  }
}

void main() {
  Future<_FakeAuthProvider> pumpRoute(
    WidgetTester tester,
    _FakeAuthService authService,
  ) async {
    final authProvider = _FakeAuthProvider();
    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => authProvider,
        child: MaterialApp(
          theme: SureTheme.light,
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ResetPasswordScreen(
                      token: 'secret-reset-token',
                      authService: authService,
                    ),
                  ),
                ),
                child: const Text('Open reset'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open reset'));
    await tester.pumpAndSettle();
    return authProvider;
  }

  testWidgets('validates password length and confirmation', (tester) async {
    await pumpRoute(tester, _FakeAuthService({'success': true}));

    await tester.enterText(find.byType(TextFormField).at(0), 'short');
    await tester.enterText(find.byType(TextFormField).at(1), 'different');
    await tester.tap(find.text('Update password'));
    await tester.pump();

    expect(
      find.text('Password must be at least 8 characters'),
      findsOneWidget,
    );
    expect(find.text('Passwords do not match'), findsOneWidget);
  });

  testWidgets('returns to the first route and shows success', (tester) async {
    final authProvider =
        await pumpRoute(tester, _FakeAuthService({'success': true}));

    await tester.enterText(find.byType(TextFormField).at(0), 'new-password');
    await tester.enterText(find.byType(TextFormField).at(1), 'new-password');
    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();

    expect(find.text('Open reset'), findsOneWidget);
    expect(find.text('Password updated. Please sign in.'), findsOneWidget);
    // Credentials are cleared even though isAuthenticated is false (expired
    // token arriving by email link).
    expect(authProvider.logoutCalled, isTrue);
  });

  testWidgets('shows a localized error and preserves password input',
      (tester) async {
    await pumpRoute(
      tester,
      _FakeAuthService({
        'success': false,
        'code': 'generic',
      }),
    );

    await tester.enterText(find.byType(TextFormField).at(0), 'new-password');
    await tester.enterText(find.byType(TextFormField).at(1), 'new-password');
    await tester.tap(find.text('Update password'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        "We couldn't reset your password. The link may be invalid or expired.",
      ),
      findsOneWidget,
    );
    expect(find.text('new-password'), findsNWidgets(2));
  });

  testWidgets('never renders the reset token', (tester) async {
    await pumpRoute(tester, _FakeAuthService({'success': true}));

    expect(find.text('secret-reset-token'), findsNothing);
  });
}
