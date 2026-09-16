import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/widgets/net_worth_card.dart';

void main() {
  setUp(() {
    // PrivacyProvider persists through SharedPreferences; mock it so the
    // provider can load/save without the platform channel, and reset the
    // cached PreferencesService so state never leaks between tests.
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
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

  // PrivacyProvider starts masked (fail-closed) and reveals only once the async
  // preference load completes, so pump a few frames to let it hydrate.
  Future<void> settleLoad(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('starts masked (fail-closed) before the preference loads',
      (tester) async {
    final provider = PrivacyProvider();
    // Checked synchronously, before the async load can turn the event loop:
    // the provider masks by default until the stored value is known.
    expect(provider.hidden, isTrue);

    // Let the load settle so the widget tree and any pending work complete.
    await tester.pumpWidget(harness(provider));
    await settleLoad(tester);
  });

  testWidgets('net worth is visible after hydration when privacy mode is off',
      (tester) async {
    await tester.pumpWidget(harness(PrivacyProvider()));
    await settleLoad(tester);

    expect(find.text(r'$29,669.71'), findsOneWidget);
    expect(find.text(r'$••••'), findsNothing);
  });

  testWidgets('toggling privacy mode masks the net worth', (tester) async {
    final privacy = PrivacyProvider();
    await tester.pumpWidget(harness(privacy));
    await settleLoad(tester);

    await privacy.setHidden(true);
    await tester.pump();

    // The real value is gone, and both amounts the harness renders — the
    // net-worth headline and the single USD asset total — collapse to the same
    // fixed mask, so exactly two appear.
    expect(find.text(r'$29,669.71'), findsNothing);
    expect(find.text(r'$••••'), findsNWidgets(2));
  });

  testWidgets('hidden state persists across provider instances',
      (tester) async {
    // First provider enables privacy mode, which persists the choice.
    final first = PrivacyProvider();
    await tester.pumpWidget(harness(first));
    await settleLoad(tester);
    await first.setHidden(true);
    await tester.pump();

    // A fresh provider reading the same persisted store loads "hidden" and
    // masks from the start.
    await tester.pumpWidget(harness(PrivacyProvider()));
    await settleLoad(tester);

    // Net-worth headline + the single USD asset total both mask.
    expect(find.text(r'$29,669.71'), findsNothing);
    expect(find.text(r'$••••'), findsNWidgets(2));
  });
}
