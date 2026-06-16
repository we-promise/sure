import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/sure_logo.dart';

void main() {
  testWidgets('renders the logomark at the requested size under the Sure theme',
      (tester) async {
    // Building under SureTheme.dark exercises the SureColors lookup that themes
    // the wordmark's `currentColor` strokes — the regression guard for routing
    // every logomark consumer through SureLogo rather than a bare SvgPicture.
    await tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.dark,
        home: const Scaffold(body: Center(child: SureLogo(size: 40))),
      ),
    );

    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.width, 40);
    expect(svg.height, 40);
  });
}
