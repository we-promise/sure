import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_text_field.dart';

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
        home: Scaffold(body: child),
      ),
    );
  }

  InputDecoration decorationOf(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).decoration!;

  Color sideColorOf(InputBorder? b) =>
      (b as OutlineInputBorder).borderSide.color;

  // Brightness-aware by contract — the field builds its chrome from the palette,
  // so assert it resolves the right tokens in both themes.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets('builds the field chrome from tokens (${brightness.name})', (
      tester,
    ) async {
      await pump(
        tester,
        const SureTextField(hint: 'Search'),
        brightness: brightness,
      );

      final deco = decorationOf(tester);
      expect(deco.filled, isTrue);
      expect(deco.fillColor, tokens.container);
      expect(sideColorOf(deco.enabledBorder), tokens.borderSecondary);
      expect(sideColorOf(deco.focusedBorder), tokens.borderPrimary);
      expect(sideColorOf(deco.errorBorder), tokens.destructive);
      expect(sideColorOf(deco.disabledBorder), tokens.borderSubdued);
      expect(
        (deco.enabledBorder as OutlineInputBorder).borderRadius,
        BorderRadius.circular(SureTokens.radiusLg),
      );
      expect(deco.hintStyle?.color, tokens.textSubdued);
      expect(deco.errorStyle?.color, tokens.destructive);
    });
  }

  testWidgets('renders an external label above the field when provided', (
    tester,
  ) async {
    await pump(tester, const SureTextField(label: 'Email', hint: 'you@x.com'));
    expect(find.text('Email'), findsOneWidget);
    // DS label, not a Material floating labelText baked into the decoration.
    expect(decorationOf(tester).labelText, isNull);
  });

  testWidgets('omits the label column when label is null', (tester) async {
    await pump(tester, const SureTextField(hint: 'Search'));
    // No DS label wrapper — the field is returned directly. (TextField's own
    // internal Columns are descendants of it, never ancestors.)
    expect(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(Column),
      ),
      findsNothing,
    );
  });

  testWidgets('the external label names the field for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const SureTextField(label: 'Email'));
    // The field is reachable by its label (Material labelText parity), and the
    // visual label is not announced as a separate detached node.
    expect(find.bySemanticsLabel('Email'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('label uses secondary when enabled, subdued when disabled',
      (tester) async {
    await pump(tester, const SureTextField(label: 'Email'));
    expect(tester.widget<Text>(find.text('Email')).style?.color,
        SureTokens.light.textSecondary);

    await pump(tester, const SureTextField(label: 'Email', enabled: false));
    expect(tester.widget<Text>(find.text('Email')).style?.color,
        SureTokens.light.textSubdued);
  });

  testWidgets('minLines alone does not trip the maxLines assert',
      (tester) async {
    // maxLines defaults to 1; a caller passing only minLines must not crash.
    await pump(tester, const SureTextField(minLines: 3));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.minLines, 3);
    expect(field.maxLines, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('obscureText is forwarded and forces a single line', (
    tester,
  ) async {
    await pump(tester, const SureTextField(obscureText: true, maxLines: 4));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.obscureText, isTrue);
    expect(field.maxLines, 1);
  });

  testWidgets('validator surfaces the error in the destructive token', (
    tester,
  ) async {
    final key = GlobalKey<FormState>();
    await pump(
      tester,
      Form(
        key: key,
        child: const SureTextField(label: 'Name', validator: _required),
      ),
    );
    key.currentState!.validate();
    await tester.pump();
    expect(find.text('Required'), findsOneWidget);
    final error = tester.widget<Text>(find.text('Required'));
    expect(error.style?.color, SureTokens.light.destructive);
  });
}

String? _required(String? v) => (v == null || v.isEmpty) ? 'Required' : null;
