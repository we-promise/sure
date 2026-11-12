import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/sso_provider.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/screens/login_screen.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

class _FakeAuthProvider extends AuthProvider {
  final List<SsoProvider>? providers;

  _FakeAuthProvider(this.providers);

  @override
  Future<List<SsoProvider>?> fetchSsoProviders() async => providers;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> pumpLogin(WidgetTester tester, List<SsoProvider>? providers) {
    return tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>(
        create: (_) => _FakeAuthProvider(providers),
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
          home: const LoginScreen(),
        ),
      ),
    );
  }

  testWidgets('renders one button per configured SSO provider', (tester) async {
    await pumpLogin(tester, const [
      SsoProvider(
          name: 'openid_connect',
          strategy: 'openid_connect',
          label: 'Authentik'),
      SsoProvider(
          name: 'google_oauth2',
          strategy: 'google_oauth2',
          label: 'Sign in with Google'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Authentik'), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
  });

  testWidgets('hides SSO when no providers are configured', (tester) async {
    await pumpLogin(tester, const []);
    await tester.pumpAndSettle();

    expect(find.text('Sign in with Google'), findsNothing);
    expect(find.text('or'), findsNothing);
  });

  testWidgets('falls back to Google when the provider list is unavailable',
      (tester) async {
    await pumpLogin(tester, null);
    await tester.pumpAndSettle();

    expect(find.text('Sign in with Google'), findsOneWidget);
  });
}
