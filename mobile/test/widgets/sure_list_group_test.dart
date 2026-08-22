import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/theme/sure_tokens.dart';
import 'package:sure_mobile/widgets/sure_icon.dart';
import 'package:sure_mobile/widgets/sure_list_group.dart';

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

  BoxDecoration groupDecorationOf(WidgetTester tester) => tester
      .widget<Container>(
        find
            .descendant(
              of: find.byType(SureListGroup),
              matching: find.byType(Container),
            )
            .first,
      )
      .decoration as BoxDecoration;

  // Brightness-aware by contract — assert the chrome resolves the right palette
  // in both themes so a token regression in either mode is caught.
  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets('paints the group chrome from tokens (${brightness.name})',
        (tester) async {
      await pump(
        tester,
        const SureListGroup(children: [SureListRow(title: 'Only row')]),
        brightness: brightness,
      );

      final deco = groupDecorationOf(tester);
      expect(deco.color, tokens.container);
      expect((deco.border as Border).top.color, tokens.borderSecondary);
      expect(deco.borderRadius, BorderRadius.circular(SureTokens.radiusLg));
      expect(deco.boxShadow, tokens.shadowXs);
    });
  }

  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets(
        'inserts subdued interior dividers but not at the edges (${brightness.name})',
        (tester) async {
      await pump(
        tester,
        const SureListGroup(children: [
          SureListRow(title: 'One'),
          SureListRow(title: 'Two'),
          SureListRow(title: 'Three'),
        ]),
        brightness: brightness,
      );

      // Three rows => exactly two interior dividers.
      final dividers =
          tester.widgetList<Divider>(find.byType(Divider)).toList();
      expect(dividers, hasLength(2));
      expect(dividers.first.color, tokens.borderSubdued);
    });
  }

  testWidgets('renders an uppercased header above the group', (tester) async {
    await pump(
      tester,
      const SureListGroup(
        header: 'Tools',
        children: [SureListRow(title: 'Calendar')],
      ),
    );
    expect(find.text('TOOLS'), findsOneWidget);
  });

  for (final (brightness, tokens) in [
    (Brightness.light, SureTokens.light),
    (Brightness.dark, SureTokens.dark),
  ]) {
    testWidgets(
        'row renders title and subtitle with tokenized colors (${brightness.name})',
        (tester) async {
      await pump(
        tester,
        const SureListGroup(
          children: [SureListRow(title: 'Calendar', subtitle: 'Monthly view')],
        ),
        brightness: brightness,
      );
      final title = tester.widget<Text>(find.text('Calendar'));
      final subtitle = tester.widget<Text>(find.text('Monthly view'));
      expect(title.style?.color, tokens.textPrimary);
      expect(subtitle.style?.color, tokens.textSecondary);
    });

    testWidgets(
        'destructive row paints the title in the destructive token (${brightness.name})',
        (tester) async {
      await pump(
        tester,
        const SureListGroup(
          children: [SureListRow(title: 'Delete account', destructive: true)],
        ),
        brightness: brightness,
      );
      final title = tester.widget<Text>(find.text('Delete account'));
      expect(title.style?.color, tokens.destructive);
    });
  }

  testWidgets(
      'showChevron renders the DS chevron, suppressed by explicit trailing',
      (tester) async {
    await pump(
      tester,
      const SureListGroup(
          children: [SureListRow(title: 'Go', showChevron: true)]),
    );
    final chevron = tester.widget<SureIcon>(find.byType(SureIcon));
    expect(chevron.name, SureIcons.chevronRight);

    await pump(
      tester,
      const SureListGroup(children: [
        SureListRow(
          title: 'Go',
          showChevron: true,
          trailing: Text('value'),
        ),
      ]),
    );
    expect(find.byType(SureIcon), findsNothing);
    expect(find.text('value'), findsOneWidget);
  });

  testWidgets('onTap fires and the tappable row uses an InkWell',
      (tester) async {
    var taps = 0;
    await pump(
      tester,
      SureListGroup(
        children: [SureListRow(title: 'Tap me', onTap: () => taps++)],
      ),
    );
    expect(find.byType(InkWell), findsOneWidget);
    await tester.tap(find.text('Tap me'));
    expect(taps, 1);
  });

  testWidgets('a row without onTap is non-interactive (no InkWell)',
      (tester) async {
    await pump(
      tester,
      const SureListGroup(children: [SureListRow(title: 'Static')]),
    );
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('a tappable row exposes button semantics (ListTile parity)',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      SureListGroup(children: [SureListRow(title: 'Go', onTap: () {})]),
    );
    final node = tester.getSemantics(find.text('Go'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.isEnabled), isTrue);
    handle.dispose();
  });

  testWidgets('an empty group builds no chrome', (tester) async {
    await pump(tester, const SureListGroup(children: []));
    // No decorated container and no dividers — it collapses rather than
    // painting an empty bordered/shadowed box.
    expect(
      find.descendant(
        of: find.byType(SureListGroup),
        matching: find.byType(Container),
      ),
      findsNothing,
    );
    expect(find.byType(Divider), findsNothing);
  });
}
