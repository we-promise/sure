import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/account.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/account_card.dart';

void main() {
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
      MaterialApp(
        theme: SureTheme.light,
        home: Scaffold(body: AccountCard(account: a)),
      ),
    );
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
