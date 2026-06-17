import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/widgets/net_worth_card.dart';

void main() {
  setUp(() {
    // PrivacyProvider persists through SharedPreferences; mock it so the
    // provider can load/save without the platform channel.
    SharedPreferences.setMockInitialValues({});
  });

  Widget harness(PrivacyProvider privacy) {
    return ChangeNotifierProvider<PrivacyProvider>.value(
      value: privacy,
      child: MaterialApp(
        home: Scaffold(
          body: NetWorthCard(
            assetTotalsByCurrency: const {'USD': 29669.71},
            liabilityTotalsByCurrency: const {},
            currentFilter: AccountFilter.all,
            onFilterChanged: (_) {},
            formatAmount: (currency, amount) =>
                '\$${amount.toStringAsFixed(2)}',
            netWorthFormatted: r'$29,669.71',
          ),
        ),
      ),
    );
  }

  testWidgets('net worth is visible when privacy mode is off', (tester) async {
    await tester.pumpWidget(harness(PrivacyProvider()));
    await tester.pump();

    expect(find.text(r'$29,669.71'), findsOneWidget);
    expect(find.text(r'$••••'), findsNothing);
  });

  testWidgets('toggling privacy mode masks the net worth', (tester) async {
    final privacy = PrivacyProvider();
    await tester.pumpWidget(harness(privacy));
    await tester.pump();

    await privacy.setHidden(true);
    await tester.pump();

    // The real value is gone and the masked token is shown. Several amounts
    // (net-worth headline + the per-currency total) collapse to the same fixed
    // mask, so assert presence rather than an exact count.
    expect(find.text(r'$29,669.71'), findsNothing);
    expect(find.text(r'$••••'), findsWidgets);
  });
}
