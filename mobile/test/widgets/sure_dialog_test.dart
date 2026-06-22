import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_button.dart';
import 'package:sure_mobile/widgets/sure_dialog.dart';

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

  BoxDecoration surfaceOf(WidgetTester tester) => tester
      .widget<Container>(
        find
            .descendant(
                of: find.byType(SureDialog), matching: find.byType(Container))
            .first,
      )
      .decoration as BoxDecoration;

  SureButton buttonWithLabel(WidgetTester tester, String label) =>
      tester.widget<SureButton>(find.widgetWithText(SureButton, label));

  // Brightness-aware by contract — assert the modal surface resolves the right
  // palette in both themes so a token regression in either mode is caught.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets('paints the Sure dialog chrome from tokens (${brightness.name})',
        (tester) async {
      await pump(
        tester,
        const SureDialog(title: 'Title', message: 'Body'),
        brightness: brightness,
      );

      final deco = surfaceOf(tester);
      expect(deco.color, tokens.container);
      expect((deco.border as Border).top.color, tokens.borderSecondary);
      expect(deco.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
      expect(deco.boxShadow, tokens.shadowLg);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });
  }

  testWidgets('asserts message and content are not both provided',
      (tester) async {
    expect(
      () => SureDialog(title: 'T', message: 'M', content: const Text('C')),
      throwsAssertionError,
    );
  });

  testWidgets('confirm: tapping the confirm action resolves true',
      (tester) async {
    late BuildContext ctx;
    await pump(tester, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));

    final result = SureDialog.confirm(
      ctx,
      title: 'Delete?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
    );
    await tester.pumpAndSettle();
    expect(find.byType(SureDialog), findsOneWidget);

    await tester.tap(find.widgetWithText(SureButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.byType(SureDialog), findsNothing);
  });

  testWidgets('confirm: tapping cancel resolves false', (tester) async {
    late BuildContext ctx;
    await pump(tester, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));

    final result = SureDialog.confirm(
      ctx,
      title: 'Sign out?',
      confirmLabel: 'Sign out',
      cancelLabel: 'Cancel',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SureButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('confirm: destructive renders the confirm in destructive variant',
      (tester) async {
    late BuildContext ctx;
    await pump(tester, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));

    SureDialog.confirm(
      ctx,
      title: 'Delete?',
      confirmLabel: 'Delete',
      cancelLabel: 'Cancel',
      destructive: true,
    );
    await tester.pumpAndSettle();

    expect(buttonWithLabel(tester, 'Delete').variant,
        SureButtonVariant.destructive);
    expect(buttonWithLabel(tester, 'Cancel').variant, SureButtonVariant.ghost);
  });

  testWidgets('confirm: confirmEnabled false disables the confirm action',
      (tester) async {
    late BuildContext ctx;
    await pump(tester, Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }));

    SureDialog.confirm(
      ctx,
      title: 'Update available',
      confirmLabel: 'Update now',
      cancelLabel: 'Cancel',
      confirmEnabled: false,
    );
    await tester.pumpAndSettle();

    expect(buttonWithLabel(tester, 'Update now').onPressed, isNull);
    expect(buttonWithLabel(tester, 'Cancel').onPressed, isNotNull);
  });

  testWidgets('renders custom content and trailing actions', (tester) async {
    await pump(
      tester,
      SureDialog(
        title: 'Rename',
        content: const TextField(key: Key('field')),
        actions: [
          SureButton(label: 'Cancel', onPressed: () {}, variant: SureButtonVariant.ghost),
          SureButton(label: 'Save', onPressed: () {}),
        ],
      ),
    );

    expect(find.byKey(const Key('field')), findsOneWidget);
    expect(find.widgetWithText(SureButton, 'Save'), findsOneWidget);
    expect(find.widgetWithText(SureButton, 'Cancel'), findsOneWidget);
  });

  testWidgets('bounds oversized content so it scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(400, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pump(
      tester,
      SureDialog(
        title: 'Busy day',
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: List.generate(
              40,
              (i) => SizedBox(height: 40, child: Text('row $i')),
            ),
          ),
        ),
        actions: [SureButton(label: 'Close', onPressed: () {})],
      ),
    );

    // The body is height-bounded and scrollable, so there is no overflow even
    // when the content far exceeds the available dialog height.
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
          of: find.byType(SureDialog), matching: find.byType(Scrollable)),
      findsWidgets,
    );
  });
}
