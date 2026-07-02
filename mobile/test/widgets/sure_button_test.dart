import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_button.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) {
    return tester.pumpWidget(
      MaterialApp(
        theme: SureTheme.light,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  BoxDecoration decoration(WidgetTester tester) =>
      tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).decoration
          as BoxDecoration;

  testWidgets('primary uses the button-primary token + inverse label', (tester) async {
    await pump(
      tester,
      SureButton(label: 'Save', onPressed: () {}),
    );
    expect(decoration(tester).color, SureTokens.light.buttonPrimary);
    final label = tester.widget<Text>(find.text('Save'));
    expect(label.style?.color, SureTokens.light.textInverse);
    expect(label.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('destructive uses the destructive token', (tester) async {
    await pump(
      tester,
      SureButton(
        label: 'Delete',
        variant: SureButtonVariant.destructive,
        onPressed: () {},
      ),
    );
    expect(decoration(tester).color, SureTokens.light.buttonDestructive);
  });

  testWidgets('secondary uses the inset-surface token', (tester) async {
    await pump(
      tester,
      SureButton(
        label: 'More',
        variant: SureButtonVariant.secondary,
        onPressed: () {},
      ),
    );
    expect(decoration(tester).color, SureTokens.light.surfaceInset);
  });

  testWidgets('outline is transparent with a border and primary text',
      (tester) async {
    await pump(
      tester,
      SureButton(
        label: 'Outline',
        variant: SureButtonVariant.outline,
        onPressed: () {},
      ),
    );
    final deco = decoration(tester);
    expect(deco.color, const Color(0x00000000));
    expect((deco.border as Border).top.color, SureTokens.light.borderSecondary);
    expect(
      tester.widget<Text>(find.text('Outline')).style?.color,
      SureTokens.light.textPrimary,
    );
  });

  testWidgets('ghost is transparent with no border', (tester) async {
    await pump(
      tester,
      SureButton(
        label: 'Ghost',
        variant: SureButtonVariant.ghost,
        onPressed: () {},
      ),
    );
    final deco = decoration(tester);
    expect(deco.color, const Color(0x00000000));
    expect(deco.border, isNull);
  });

  testWidgets('renders in an unbounded-width Row without asserting',
      (tester) async {
    // Regression: a bare Flexible in the label Row used to throw under
    // unbounded horizontal constraints; an inline (non-full-width) button must
    // self-size instead.
    await pump(
      tester,
      Row(children: [SureButton(label: 'Inline', onPressed: () {})]),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Inline'), findsOneWidget);
  });

  testWidgets('clears the pressed highlight if disabled mid-press',
      (tester) async {
    // Regression: if disabled while pressed, onTapUp/onTapCancel never fire, so
    // didUpdateWidget must reset _pressed (otherwise the hover bg sticks once
    // the button is re-enabled).
    Widget build(bool loading) => MaterialApp(
          theme: SureTheme.light,
          home: Scaffold(
            body: Center(
              child: SureButton(
                key: const ValueKey('btn'),
                label: 'Go',
                loading: loading,
                onPressed: () {},
              ),
            ),
          ),
        );

    await tester.pumpWidget(build(false));
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(SureButton)));
    await tester.pump(); // onTapDown -> _pressed = true
    await tester.pumpWidget(build(true)); // disabled mid-press -> reset
    await tester.pump();
    await tester.pumpWidget(build(false)); // re-enabled
    await tester.pump();
    // Background must be the base token, not the pressed (hover) token.
    expect(decoration(tester).color, SureTokens.light.buttonPrimary);
    await gesture.up();
  });

  testWidgets('tap fires onPressed when enabled', (tester) async {
    var taps = 0;
    await pump(tester, SureButton(label: 'Go', onPressed: () => taps++));
    await tester.tap(find.byType(SureButton));
    expect(taps, 1);
  });

  testWidgets('null onPressed disables taps and dims the button', (tester) async {
    await pump(
      tester,
      const SureButton(label: 'Disabled', onPressed: null),
    );
    // Tapping a disabled button must not throw, and it stays dimmed.
    await tester.tap(find.byType(SureButton));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.5);
  });

  testWidgets('loading shows a spinner and blocks taps', (tester) async {
    var taps = 0;
    await pump(
      tester,
      SureButton(label: 'Saving', onPressed: () => taps++, loading: true),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byType(SureButton));
    expect(taps, 0);
  });

  testWidgets('activates via the keyboard (focus + Enter)', (tester) async {
    var taps = 0;
    await pump(tester, SureButton(label: 'Go', onPressed: () => taps++));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  testWidgets('fullWidth fills the available width', (tester) async {
    await pump(
      tester,
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: SureButton(label: 'Wide', fullWidth: true, onPressed: () {}),
      ),
    );
    expect(tester.getSize(find.byType(SureButton)).width, 300);
  });

  testWidgets('non-fullWidth hugs its content', (tester) async {
    await pump(
      tester,
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: SureButton(label: 'Hi', onPressed: () {}),
      ),
    );
    expect(tester.getSize(find.byType(SureButton)).width, lessThan(300));
  });

  testWidgets('leading icon inherits the variant foreground via IconTheme',
      (tester) async {
    // The button owns its content foreground: a leading icon with no explicit
    // color must pick up the variant foreground (so call sites don't hardcode
    // it). SureIcon resolves color from the ambient IconTheme.
    Color? primaryIconColor;
    await pump(
      tester,
      SureButton(
        label: 'Retry',
        onPressed: () {},
        leading: Builder(builder: (ctx) {
          primaryIconColor = IconTheme.of(ctx).color;
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(primaryIconColor, SureTokens.light.textInverse);

    Color? outlineIconColor;
    await pump(
      tester,
      SureButton(
        label: 'Edit',
        variant: SureButtonVariant.outline,
        onPressed: () {},
        leading: Builder(builder: (ctx) {
          outlineIconColor = IconTheme.of(ctx).color;
          return const SizedBox.shrink();
        }),
      ),
    );
    expect(outlineIconColor, SureTokens.light.textPrimary);
  });

  testWidgets('size maps to the canonical min-height', (tester) async {
    await pump(
      tester,
      SureButton(label: 'Big', size: SureButtonSize.lg, onPressed: () {}),
    );
    expect(
      tester
          .widget<AnimatedContainer>(find.byType(AnimatedContainer))
          .constraints
          ?.minHeight,
      48,
    );
  });
}
