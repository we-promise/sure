import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/providers/auth_provider.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/budgets_screen.dart';
import 'package:sure_mobile/services/budgets_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';

import '../support/budget_fixtures.dart';

class _Auth extends ChangeNotifier implements AuthProvider {
  final String? token;
  _Auth([this.token = 'token']);
  @override
  Future<String?> getValidAccessToken() async => token;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget harness(http.Client client,
        {bool hidden = false,
        bool dark = false,
        String? token = 'token',
        double textScale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => _Auth(token)),
        ChangeNotifierProvider<PrivacyProvider>(
            create: (_) => PrivacyProvider(initialHidden: hidden)),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark ? SureTheme.dark : SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: BudgetsScreen(service: BudgetsService(client: client)),
      ),
    );

http.Client fixtureClient(List<String> paths, {bool shared = false}) =>
    MockClient((request) async {
      paths.add(request.url.path);
      final data = switch (request.url.path) {
        '/api/v1/budgets' => budgetPage(totalPages: 2),
        '/api/v1/budgets/budget-1' => budgetJson(detail: true),
        '/api/v1/budget_categories' => categoryPage(),
        _ => categoryJson(detail: true, shared: shared),
      };
      return http.Response(jsonEncode(data), 200);
    });

Future<void> openBudget(WidgetTester tester) async {
  await tester.tap(find.text('September budget'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows loading then a useful empty state', (tester) async {
    final pending = Completer<http.Response>();
    await tester.pumpWidget(harness(MockClient((_) => pending.future)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete(http.Response(jsonEncode(budgetPage(empty: true)), 200));
    await tester.pumpAndSettle();
    expect(find.textContaining('No budgets yet'), findsOneWidget);
  });

  testWidgets(
      'loads category spending only when expanded and preserves server remaining',
      (tester) async {
    final paths = <String>[];
    await tester.pumpWidget(harness(fixtureClient(paths)));
    await tester.pumpAndSettle();
    expect(paths, ['/api/v1/budgets']);
    expect(find.text(r'$0.00'), findsNothing);
    await openBudget(tester);
    expect(find.text(r'-$50.00'), findsOneWidget);
    expect(find.text('Over budget'), findsOneWidget);
    expect(paths, isNot(contains('/api/v1/budget_categories/category-1')));
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(paths.last, '/api/v1/budget_categories/category-1');
    expect(find.text(r'$150.00'), findsOneWidget);
    expect(find.text('Carried over'), findsOneWidget);
    final bars = tester
        .widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator))
        .toList();
    expect(bars.map((bar) => bar.value), [1.0, 0.4]);
  });

  testWidgets('privacy mode hides amounts, progress and over-budget status',
      (tester) async {
    await tester.pumpWidget(harness(fixtureClient([]), hidden: true));
    await tester.pumpAndSettle();
    expect(find.text(r'$1,000.00'), findsNothing);
    await openBudget(tester);
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.text(r'$150.00'), findsNothing);
    expect(find.text('Over budget'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('••••'), findsWidgets);
  });

  testWidgets(
      'shared categories explain the parent limit without a misleading ratio',
      (tester) async {
    await tester.pumpWidget(harness(fixtureClient([], shared: true)));
    await tester.pumpAndSettle();
    await openBudget(tester);
    await tester.tap(find.text('Groceries'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Shares its parent's budget"), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('supports retry after a failed request', (tester) async {
    var calls = 0;
    await tester.pumpWidget(harness(MockClient((_) async {
      calls++;
      return calls == 1
          ? http.Response('offline', 503)
          : http.Response(jsonEncode(budgetPage()), 200);
    })));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to load budgets'), findsOneWidget);
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.text('September budget'), findsOneWidget);
  });

  testWidgets('expired sessions do not make an unauthenticated request',
      (tester) async {
    var called = false;
    await tester.pumpWidget(harness(MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    }), token: null));
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(find.textContaining('Your session has expired'), findsOneWidget);
  });

  testWidgets('pagination requests the next page', (tester) async {
    final pages = <String?>[];
    await tester.pumpWidget(harness(MockClient((request) async {
      final page = request.url.queryParameters['page'];
      pages.add(page);
      return http.Response(
          jsonEncode(budgetPage(page: int.parse(page!), totalPages: 2)), 200);
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(pages, ['1', '2']);
    expect(find.text('Page 2 of 2'), findsOneWidget);
  });

  testWidgets(
      'late responses after leaving the screen do not update disposed state',
      (tester) async {
    final pending = Completer<http.Response>();
    await tester.pumpWidget(harness(MockClient((_) => pending.future)));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(http.Response(jsonEncode(budgetPage()), 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow screen with large text in dark mode',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester
        .pumpWidget(harness(fixtureClient([]), dark: true, textScale: 2));
    await tester.pumpAndSettle();
    await openBudget(tester);
    expect(tester.takeException(), isNull);
  });
}
