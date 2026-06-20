import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/currency_filter.dart';
import 'package:sure_mobile/widgets/sure_chip.dart';

// Proof that migrating the filter chips to SureChip preserved the selection
// behavior (per-currency toggle + the "All" reset).
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Set<String> selected,
    required ValueChanged<Set<String>> onChanged,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.light,
        home: Scaffold(
          body: CurrencyFilter(
            availableCurrencies: const {'USD', 'EUR', 'GBP'},
            selectedCurrencies: selected,
            onSelectionChanged: onChanged,
          ),
        ),
      ),
    );
  }

  testWidgets('renders an "All" chip plus one SureChip per currency',
      (tester) async {
    await pump(tester, selected: const {}, onChanged: (_) {});
    expect(find.byType(SureChip), findsNWidgets(4)); // All + 3 currencies
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('selecting a currency reports just that currency',
      (tester) async {
    Set<String>? latest;
    await pump(tester, selected: const {}, onChanged: (s) => latest = s);
    await tester.tap(find.text('EUR (€)'));
    expect(latest, {'EUR'});
  });

  testWidgets('tapping "All" resets the selection', (tester) async {
    Set<String>? latest;
    await pump(tester, selected: const {'EUR'}, onChanged: (s) => latest = s);
    await tester.tap(find.text('All'));
    expect(latest, isEmpty);
  });
}
