import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/screens/sso_onboarding_screen.dart';

void main() {
  testWidgets('defaults to accepting an invitation when one is pending', (
    tester,
  ) async {
    final authProvider = AuthProvider();

    await authProvider.handleSsoCallback(
      Uri.parse(
        'companion://auth/callback?status=account_not_linked'
        '&linking_code=test-code'
        '&email=person%40example.com'
        '&first_name=Pat'
        '&last_name=Example'
        '&allow_account_creation=true'
        '&has_pending_invitation=true',
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthProvider>.value(
        value: authProvider,
        child: const MaterialApp(home: SsoOnboardingScreen()),
      ),
    );

    expect(find.text('Accept Invitation'), findsNWidgets(2));
    expect(find.text('Link Account'), findsNothing);
    expect(
      find.text(
        'You have a pending invitation. Accept it to join an existing household.',
      ),
      findsOneWidget,
    );
  });
}
