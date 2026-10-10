import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/monthly_spending.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/services/monthly_spending_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/monthly_spending_card.dart';
import '../support/monthly_spending_fixture.dart';

void main() {
  MonthlySpendingResult ready({bool empty = false, int rates = 0}) =>
      MonthlySpendingResult(
          MonthlySpendingStatus.ready,
          MonthlySpendingData.fromJson(monthlySpendingFixture(
              emptySelection: empty, missingRates: rates)));

  Widget app(MonthlySpendingLoader loader,
          {bool hidden = false, double scale = 1, int revision = 0}) =>
      ChangeNotifierProvider(
        create: (_) => PrivacyProvider(initialHidden: hidden),
        child: MaterialApp(
          theme: SureTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
              body: MediaQuery(
                  data: MediaQueryData(
                      size: const Size(320, 800),
                      textScaler: TextScaler.linear(scale)),
                  child: SingleChildScrollView(
                      child: MonthlySpendingCard(
                          loader: loader, revision: revision)))),
        ),
      );

  testWidgets(
      'shows partial month, FX warning and category details on a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app((_) async => ready(rates: 1), scale: 2));
    await tester.pumpAndSettle();
    expect(find.text('Spending by month'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Month in progress'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('privacy mode hides chart geometry and monetary text',
      (tester) async {
    await tester.pumpWidget(app((_) async => ready(), hidden: true));
    await tester.pumpAndSettle();
    expect(find.text('Chart hidden in privacy mode.'), findsOneWidget);
    expect(find.text(r'$30.00'), findsNothing);
    expect(find.text(r'$••••'), findsWidgets);
  });

  testWidgets('explicit empty selection has no bars', (tester) async {
    await tester.pumpWidget(app((_) async => ready(empty: true)));
    await tester.pumpAndSettle();
    expect(
        find.text('Select at least one account and category to show spending.'),
        findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('old servers and disabled preview hide the card', (tester) async {
    await tester.pumpWidget(app((_) async =>
        const MonthlySpendingResult(MonthlySpendingStatus.unavailable)));
    await tester.pumpAndSettle();
    expect(find.text('Spending by month'), findsNothing);
  });

  testWidgets('slow older requests cannot overwrite refreshed data',
      (tester) async {
    final old = Completer<MonthlySpendingResult>();
    var calls = 0;
    Future<MonthlySpendingResult> loader(MonthlySpendingSelection _) =>
        ++calls == 1 ? old.future : Future.value(ready(empty: true));
    await tester.pumpWidget(app(loader));
    await tester.pump();
    await tester.pumpWidget(app(loader, revision: 1));
    await tester.pumpAndSettle();
    old.complete(ready());
    await tester.pumpAndSettle();
    expect(
        find.text('Select at least one account and category to show spending.'),
        findsOneWidget);
    expect(find.text('Food'), findsNothing);
  });
  testWidgets(
      'month tap changes details and filter presets preserve explicit none',
      (tester) async {
    final selections = <MonthlySpendingSelection>[];
    Future<MonthlySpendingResult> loader(
        MonthlySpendingSelection selection) async {
      selections.add(selection);
      return ready(empty: selection.accountIds?.isEmpty == true);
    }

    await tester.pumpWidget(app(loader));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(InkWell, 'Dec 2024').first);
    await tester.pumpAndSettle();
    expect(find.text(r'$20.00'), findsNWidgets(2));
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Previous year'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('None').first);
    await tester.tap(find.text('None').first);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(selections.last.from, '2024-01-01');
    expect(selections.last.to, '2024-12-01');
    expect(selections.last.accountIds, isEmpty);
    expect(
        find.text('Select at least one account and category to show spending.'),
        findsOneWidget);
  });
  testWidgets('preview card stays hidden until the server confirms access',
      (tester) async {
    final request = Completer<MonthlySpendingResult>();
    await tester.pumpWidget(app((_) => request.future));
    expect(find.text('Spending by month'), findsNothing);
    request.complete(const MonthlySpendingResult(MonthlySpendingStatus.error));
    await tester.pumpAndSettle();
    expect(find.text('Spending by month'), findsNothing);
  });
}
