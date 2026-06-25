import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_segmented_control.dart';

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

  Widget control(String selected, ValueChanged<String> onChanged) =>
      SureSegmentedControl<String>(
        selected: selected,
        onChanged: onChanged,
        segments: const [
          SureSegment(value: 'expense', label: 'Expense'),
          SureSegment(value: 'income', label: 'Income'),
        ],
      );

  // The selected segment's raised fill is the only chrome that differs by
  // brightness, so assert it resolves correctly in both.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets(
        'selected segment is a raised surface above the track '
        '(${brightness.name})', (tester) async {
      await pump(tester, control('expense', (_) {}), brightness: brightness);

      // Track decoration — the control's only plain Container (segments use
      // AnimatedContainer), so this is unambiguous.
      final track = tester
          .widget<Container>(find
              .descendant(
                of: find.byType(SureSegmentedControl<String>),
                matching: find.byType(Container),
              )
              .first)
          .decoration as BoxDecoration;
      expect(track.color, tokens.surfaceInset);

      // Selected segment fill = brightness-appropriate raised token + shadow.
      final selectedBg = brightness == Brightness.light
          ? tokens.container
          : tokens.containerInsetHover;
      final selectedSeg = tester
          .widget<AnimatedContainer>(
            find
                .ancestor(
                  of: find.text('Expense'),
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          )
          .decoration as BoxDecoration;
      expect(selectedSeg.color, selectedBg);
      expect(selectedSeg.boxShadow, tokens.shadowXs);

      // Unselected segment is flat (transparent, no shadow).
      final unselectedSeg = tester
          .widget<AnimatedContainer>(
            find
                .ancestor(
                  of: find.text('Income'),
                  matching: find.byType(AnimatedContainer),
                )
                .first,
          )
          .decoration as BoxDecoration;
      expect(unselectedSeg.color, const Color(0x00000000));
      expect(unselectedSeg.boxShadow, isEmpty);
    });
  }

  testWidgets('selected vs unselected labels use the right tokens', (
    tester,
  ) async {
    await pump(tester, control('expense', (_) {}));
    expect(
      tester.widget<Text>(find.text('Expense')).style?.color,
      SureTokens.light.textPrimary,
    );
    expect(
      tester.widget<Text>(find.text('Income')).style?.color,
      SureTokens.light.textSecondary,
    );
  });

  testWidgets('tapping a segment reports its value', (tester) async {
    String? picked;
    await pump(tester, control('expense', (v) => picked = v));
    await tester.tap(find.text('Income'));
    expect(picked, 'income');
  });

  testWidgets('each segment is keyboard/switch focusable + activatable',
      (tester) async {
    // FocusableActionDetector per segment = keyboard/switch parity with the
    // Material SegmentedButton it replaced (regression guard for the focus gap).
    await pump(tester, control('expense', (_) {}));
    expect(find.byType(FocusableActionDetector), findsNWidgets(2));
  });

  testWidgets('a selected value matching no segment highlights nothing',
      (tester) async {
    await pump(tester, control('neither', (_) {}));
    for (final t in tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))) {
      expect((t.decoration as BoxDecoration).color, const Color(0x00000000));
    }
  });

  testWidgets('each segment exposes button + selected semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, control('expense', (_) {}));
    expect(
      tester
          .getSemantics(find.text('Expense'))
          .hasFlag(SemanticsFlag.isSelected),
      isTrue,
    );
    expect(
      tester
          .getSemantics(find.text('Income'))
          .hasFlag(SemanticsFlag.isSelected),
      isFalse,
    );
    expect(
      tester.getSemantics(find.text('Expense')).hasFlag(SemanticsFlag.isButton),
      isTrue,
    );
    handle.dispose();
  });
}
