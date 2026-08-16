import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_card.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child,
      {Brightness brightness = Brightness.light}) {
    return tester.pumpWidget(
      MaterialApp(
        theme:
            brightness == Brightness.light ? SureTheme.light : SureTheme.dark,
        home: Scaffold(body: child),
      ),
    );
  }

  BoxDecoration decorationOf(WidgetTester tester) => tester
      .widget<Container>(
        find
            .descendant(of: find.byType(SureCard), matching: find.byType(Container))
            .first,
      )
      .decoration as BoxDecoration;

  // Brightness-aware by contract — assert the chrome resolves the right palette
  // in both themes so a token regression in either mode is caught.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets('paints the Sure card chrome from tokens (${brightness.name})',
        (tester) async {
      await pump(tester, const SureCard(child: Text('Body')),
          brightness: brightness);

      final deco = decorationOf(tester);
      expect(deco.color, tokens.container);
      expect((deco.border as Border).top.color, tokens.borderSecondary);
      expect(deco.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
      expect(deco.boxShadow, tokens.shadowXs);
      expect(find.text('Body'), findsOneWidget);
    });
  }

  testWidgets('elevated: false drops the shadow', (tester) async {
    await pump(tester, const SureCard(elevated: false, child: Text('Body')));
    expect(decorationOf(tester).boxShadow, isNull);
  });

  testWidgets('onTap fires and is clipped to the card (InkWell present)',
      (tester) async {
    var taps = 0;
    await pump(
      tester,
      SureCard(onTap: () => taps++, child: const Text('Tap me')),
    );
    final inkWell = tester.widget<InkWell>(find.byType(InkWell));
    expect(inkWell.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
    await tester.tap(find.text('Tap me'));
    expect(taps, 1);
  });

  testWidgets('is non-interactive without onTap (no InkWell)', (tester) async {
    await pump(tester, const SureCard(child: Text('Body')));
    expect(find.byType(InkWell), findsNothing);
  });
}
