import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_card.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.light,
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

  testWidgets('paints the Sure card chrome from tokens', (tester) async {
    await pump(tester, const SureCard(child: Text('Body')));

    final deco = decorationOf(tester);
    expect(deco.color, SureTokens.light.container);
    expect((deco.border as Border).top.color, SureTokens.light.borderSecondary);
    expect(deco.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
    expect(deco.boxShadow, SureTokens.light.shadowXs);
    expect(find.text('Body'), findsOneWidget);
  });

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
    expect(find.byType(InkWell), findsOneWidget);
    await tester.tap(find.text('Tap me'));
    expect(taps, 1);
  });

  testWidgets('is non-interactive without onTap (no InkWell)', (tester) async {
    await pump(tester, const SureCard(child: Text('Body')));
    expect(find.byType(InkWell), findsNothing);
  });
}
