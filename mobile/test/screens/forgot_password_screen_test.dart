import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/screens/forgot_password_screen.dart';
import 'package:sure_mobile/services/auth_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

class _FakeAuthService extends AuthService {
  _FakeAuthService(this.result);

  final Map<String, dynamic> result;
  int requestCount = 0;

  @override
  Future<Map<String, dynamic>> requestPasswordReset({
    required String email,
  }) async {
    requestCount += 1;
    return result;
  }
}

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    _FakeAuthService authService,
  ) {
    return tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.light,
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ForgotPasswordScreen(authService: authService),
      ),
    );
  }

  testWidgets('validates the email before requesting a reset', (tester) async {
    final authService = _FakeAuthService({'success': true});
    await pumpScreen(tester, authService);

    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    expect(find.text('Please enter your email'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'invalid');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    expect(find.text('Please enter a valid email'), findsOneWidget);
    expect(authService.requestCount, 0);
  });

  testWidgets('shows an account-safe confirmation after success',
      (tester) async {
    final authService = _FakeAuthService({'success': true});
    await pumpScreen(tester, authService);

    await tester.enterText(find.byType(TextFormField), 'user@example.test');
    await tester.tap(find.text('Send reset link'));
    await tester.pumpAndSettle();

    expect(find.text('Check your inbox'), findsOneWidget);
    expect(
      find.textContaining('If an account exists for that email'),
      findsOneWidget,
    );
    expect(find.text('user@example.test'), findsNothing);
  });

  testWidgets('keeps the email and shows a rate-limit error', (tester) async {
    final authService = _FakeAuthService({
      'success': false,
      'rateLimited': true,
    });
    await pumpScreen(tester, authService);

    await tester.enterText(find.byType(TextFormField), 'user@example.test');
    await tester.tap(find.text('Send reset link'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Too many reset requests'), findsOneWidget);
    expect(find.text('user@example.test'), findsOneWidget);
  });

  testWidgets('keeps the email and shows a retryable network error',
      (tester) async {
    final authService = _FakeAuthService({
      'success': false,
      'retryable': true,
      'error': 'Network unavailable',
    });
    await pumpScreen(tester, authService);

    await tester.enterText(find.byType(TextFormField), 'user@example.test');
    await tester.tap(find.text('Send reset link'));
    await tester.pumpAndSettle();

    expect(find.textContaining("couldn't reach your server"), findsOneWidget);
    expect(find.text('user@example.test'), findsOneWidget);
  });
}
