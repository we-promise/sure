import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_chip.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Brightness brightness = Brightness.light,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        theme:
            brightness == Brightness.light ? SureTheme.light : SureTheme.dark,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Material materialOf(WidgetTester tester) => tester.widget<Material>(
        find
            .descendant(
                of: find.byType(SureChip), matching: find.byType(Material))
            .first,
      );

  // Brightness-aware by contract — assert both selection states resolve the
  // right tokens in light and dark.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets(
      'selected chip fills with the neutral token (${brightness.name})',
      (tester) async {
        await pump(
          tester,
          const SureChip(label: 'USD', selected: true),
          brightness: brightness,
        );
        expect(materialOf(tester).color, tokens.buttonPrimary);
        final label = tester.widget<Text>(find.text('USD'));
        expect(label.style?.color, tokens.textInverse);
        expect(label.style?.fontWeight, FontWeight.w600);
        // Filled chip drops the border.
        expect(
          (materialOf(tester).shape as StadiumBorder).side,
          BorderSide.none,
        );
      },
    );

    testWidgets(
      'unselected chip is a bordered transparent pill (${brightness.name})',
      (tester) async {
        await pump(
          tester,
          const SureChip(label: 'USD'),
          brightness: brightness,
        );
        expect(materialOf(tester).color, const Color(0x00000000));
        expect(
          (materialOf(tester).shape as StadiumBorder).side.color,
          tokens.borderSecondary,
        );
        final label = tester.widget<Text>(find.text('USD'));
        expect(label.style?.color, tokens.textSecondary);
        expect(label.style?.fontWeight, FontWeight.w500);
      },
    );
  }

  testWidgets('tapping reports the next selected value', (tester) async {
    bool? next;
    await pump(
      tester,
      SureChip(label: 'USD', selected: false, onSelected: (v) => next = v),
    );
    await tester.tap(find.byType(SureChip));
    expect(next, isTrue);

    await pump(
      tester,
      SureChip(label: 'USD', selected: true, onSelected: (v) => next = v),
    );
    await tester.tap(find.byType(SureChip));
    expect(next, isFalse);
  });

  testWidgets('exposes button + selected semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      SureChip(label: 'USD', selected: true, onSelected: (_) {}),
    );
    final node = tester.getSemantics(find.byType(SureChip));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.isSelected), isTrue);
    handle.dispose();
  });

  testWidgets('a chip without onSelected is non-interactive', (tester) async {
    await pump(tester, const SureChip(label: 'USD'));
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
  });

  testWidgets('enabled: false is non-interactive and dimmed', (tester) async {
    var taps = 0;
    await pump(
      tester,
      SureChip(label: 'USD', enabled: false, onSelected: (_) => taps++),
    );
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.5);
    await tester.tap(find.byType(SureChip));
    expect(taps, 0);
  });

  testWidgets('meets the minimum tap-target height', (tester) async {
    await pump(tester, const SureChip(label: 'USD'));
    expect(
        tester.getSize(find.byType(SureChip)).height, greaterThanOrEqualTo(44));
  });
}
