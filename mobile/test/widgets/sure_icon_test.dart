import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/widgets/sure_icon.dart';

void main() {
  SvgPicture svg(WidgetTester tester) =>
      tester.widget<SvgPicture>(find.byType(SvgPicture));

  testWidgets('renders the named Lucide asset at the requested size',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SureIcon(SureIcons.wallet, size: SureIconSize.lg),
      ),
    );
    expect(svg(tester).width, SureIconSize.lg);
    expect(svg(tester).height, SureIconSize.lg);
  });

  testWidgets('paints at its size inside a larger tight-constrained parent',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: SureIcon(SureIcons.landmark, size: SureIconSize.lg),
          ),
        ),
      ),
    );
    // The glyph must stay 24 (not stretch to the 48 container) — regression for
    // the account-card icon rendering at 2x.
    expect(tester.getSize(find.byType(SvgPicture)), const Size(24, 24));
  });

  testWidgets('falls back to the ambient IconTheme size when size is null',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: IconTheme(
          data: IconThemeData(size: 30),
          child: SureIcon(SureIcons.refresh),
        ),
      ),
    );
    expect(svg(tester).width, 30);
    expect(svg(tester).height, 30);
  });

  testWidgets('a meaningful icon exposes its label; a decorative one does not',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SureIcon(SureIcons.refresh, semanticLabel: 'Refresh'),
      ),
    );
    expect(find.bySemanticsLabel('Refresh'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(home: SureIcon(SureIcons.wallet)),
    );
    expect(find.bySemanticsLabel('wallet'), findsNothing);
  });
}
