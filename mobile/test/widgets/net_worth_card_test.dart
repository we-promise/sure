import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/net_worth_card.dart';

void main() {
  Future<void> pump(WidgetTester tester, {Brightness brightness = Brightness.light}) {
    return tester.pumpWidget(
      MaterialApp(
        theme:
            brightness == Brightness.light ? SureTheme.light : SureTheme.dark,
        home: Scaffold(
          body: NetWorthCard(
            assetTotalsByCurrency: const {'USD': 125000.0},
            liabilityTotalsByCurrency: const {'USD': 32000.0},
            currentFilter: AccountFilter.all,
            onFilterChanged: (_) {},
            formatAmount: (currency, amount) =>
                '\$${amount.toStringAsFixed(0)} $currency',
            netWorthFormatted: '\$93,000',
          ),
        ),
      ),
    );
  }

  // The hero card must resolve the canonical Sure card chrome (mirrors
  // SureCard) in both themes, so a token regression in either mode is caught.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets('net worth card paints Sure card chrome from tokens (${brightness.name})',
        (tester) async {
      await pump(tester, brightness: brightness);

      final deco = tester
          .widget<Container>(
            find.byKey(const ValueKey('netWorthCardChrome')),
          )
          .decoration as BoxDecoration;

      expect(deco.color, tokens.container);
      expect((deco.border as Border).top.color, tokens.borderSecondary);
      expect(deco.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
      expect(deco.boxShadow, tokens.shadowXs);
      expect(find.text('\$93,000'), findsOneWidget);
    });
  }
}
