import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/models/account.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/account_card.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
  });

  Account account(String classification) => Account(
        id: '1',
        name: 'Test account',
        balance: 'USD 100.00',
        currency: 'USD',
        accountType:
            classification == 'liability' ? 'credit_card' : 'depository',
        classification: classification,
      );

  Future<void> pump(WidgetTester tester, Account a) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<PrivacyProvider>(
        create: (_) => PrivacyProvider(),
        child: MaterialApp(
          theme: SureTheme.light,
          home: Scaffold(body: AccountCard(account: a)),
        ),
      ),
    );
    // PrivacyProvider is fail-closed: it starts masked and reveals once the
    // (mock-empty -> privacy off) preference load completes. Pump a few frames
    // so the real balance is shown before asserting on it.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('liability balance uses the destructive design-system token',
      (tester) async {
    await pump(tester, account('liability'));
    final balance = tester.widget<Text>(find.text('USD 100.00'));
    expect(balance.style?.color, SureTokens.light.destructive);
  });

  testWidgets('asset balance keeps default (non-destructive) color',
      (tester) async {
    await pump(tester, account('asset'));
    final balance = tester.widget<Text>(find.text('USD 100.00'));
    expect(balance.style?.color, isNot(SureTokens.light.destructive));
  });
}
