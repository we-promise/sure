import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/providers/budgets_provider.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/budget_category_transactions_screen.dart';
import 'package:sure_mobile/screens/budgets_screen.dart';
import 'package:sure_mobile/services/budgets_service.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/budget_category_row.dart';
import 'package:sure_mobile/widgets/budget_progress_bar.dart';

import '../support/budget_fixtures.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
  });

  BudgetsProvider buildProvider({List<Map<String, dynamic>>? budgets}) {
    return BudgetsProvider(
      service: BudgetsService(client: budgetsMockClient(budgets: budgets)),
      clock: () => DateTime(2026, 10, 19),
    );
  }

  Widget harness(
    BudgetsProvider provider, {
    required bool hidden,
    Future<String?> Function()? loader,
    Locale locale = const Locale('en'),
  }) {
    return ChangeNotifierProvider<PrivacyProvider>(
      create: (_) => PrivacyProvider(initialHidden: hidden),
      child: MaterialApp(
        theme: SureTheme.light,
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: BudgetsScreen(
          provider: provider,
          accessTokenLoader: loader ?? () async => 'token',
        ),
      ),
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    BudgetsProvider provider, {
    bool hidden = false,
    Future<String?> Function()? loader,
    Locale locale = const Locale('en'),
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(provider, hidden: hidden, loader: loader, locale: locale),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows totals, nested categories and over-budget state',
      (tester) async {
    await pumpScreen(tester, buildProvider());

    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('Budgeted'), findsOneWidget);
    expect(find.text(r'$2,000.00'), findsOneWidget);
    expect(find.text(r'$1,500.00'), findsOneWidget);
    expect(find.text(r'$500.00'), findsOneWidget);

    expect(find.byType(BudgetCategoryRow), findsNWidgets(4));
    expect(find.text('Gifts'), findsNothing);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text(r'$120.00 over'), findsOneWidget);
    expect(find.text('Over budget'), findsOneWidget);
    expect(find.text('Near limit'), findsOneWidget);
    expect(find.text('Shared budget'), findsOneWidget);
    expect(find.text(r'+$50.00 rolled over'), findsOneWidget);

    // Planned future months stay reachable from the current month.
    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('over-budget filter shows only over-budget lines',
      (tester) async {
    await pumpScreen(tester, buildProvider());

    await tester.tap(find.text('Over budget (1)'));
    await tester.pumpAndSettle();

    expect(find.byType(BudgetCategoryRow), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Transport'), findsNothing);
  });

  testWidgets('privacy mode masks every amount', (tester) async {
    await pumpScreen(tester, buildProvider(), hidden: true);

    expect(find.text(r'$2,000.00'), findsNothing);
    expect(find.textContaining(r'$1,500.00'), findsNothing);
    expect(find.text(r'$••••'), findsWidgets);
    expect(find.text(r'$•••• over'), findsOneWidget);
    // The bars would give the share spent away.
    final bars =
        tester.widgetList<BudgetProgressBar>(find.byType(BudgetProgressBar));
    expect(bars, isNotEmpty);
    expect(bars.every((bar) => bar.hidden), isTrue);
  });

  testWidgets('formats the month in Swedish without extra date setup',
      (tester) async {
    await pumpScreen(
      tester,
      buildProvider(budgets: []),
      locale: const Locale('sv'),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('oktober 2026'), findsWidgets);
  });

  testWidgets('month without a budget shows the empty state', (tester) async {
    await pumpScreen(tester, buildProvider(budgets: []));

    expect(find.text('No budget for October 2026'), findsOneWidget);
    expect(find.byType(BudgetCategoryRow), findsNothing);
  });

  testWidgets('previous month loads that month', (tester) async {
    await pumpScreen(tester, buildProvider());

    await tester.tap(find.byTooltip('Previous month'));
    await tester.pumpAndSettle();

    expect(find.text('No budget for September 2026'), findsOneWidget);
    final next = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.chevron_right),
    );
    expect(next.onPressed, isNotNull);
  });

  testWidgets('tapping a parent opens its transactions with subcategories',
      (tester) async {
    await pumpScreen(tester, buildProvider());

    await tester.tap(find.text('Food'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final screen = tester.widget<BudgetCategoryTransactionsScreen>(
      find.byType(BudgetCategoryTransactionsScreen),
    );
    expect(screen.categoryIds, [
      'cat_food',
      'cat_groceries',
      'cat_restaurants',
    ]);
    expect(screen.startDate, DateTime(2026, 10, 1));
    expect(screen.endDate, DateTime(2026, 10, 31));
  });

  testWidgets('a failed refresh keeps the loaded month with a banner',
      (tester) async {
    final inner = budgetsMockHandler();
    var fail = false;
    final provider = BudgetsProvider(
      service: BudgetsService(
        client: MockClient((request) async {
          if (fail) throw http.ClientException('connection reset');
          return inner(request);
        }),
      ),
      clock: () => DateTime(2026, 10, 19),
    );
    await pumpScreen(tester, provider);
    expect(find.text('Budgeted'), findsOneWidget);

    fail = true;
    await provider.loadMonth(accessToken: 'token', forceRefresh: true);
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load budgets"), findsNothing);
    expect(find.text('Budgeted'), findsOneWidget);
    expect(
      find.text("Couldn't refresh. Showing the figures loaded earlier."),
      findsOneWidget,
    );

    fail = false;
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(
      find.text("Couldn't refresh. Showing the figures loaded earlier."),
      findsNothing,
    );
  });

  testWidgets('without an access token shows the session-expired state',
      (tester) async {
    await pumpScreen(tester, buildProvider(), loader: () async => null);

    expect(
      find.text('Your session has expired. Please sign in again.'),
      findsOneWidget,
    );
  });

  testWidgets('switching budgets after the session expired says so',
      (tester) async {
    String? token = 'token';
    await pumpScreen(
      tester,
      buildProvider(
        budgets: [
          budgetJson(id: 'budget_oct'),
          budgetJson(id: 'budget_oct_personal', actualCents: 1000),
        ],
      ),
      loader: () async => token,
    );

    token = null;
    await tester.tap(find.text('Budget 2'));
    await tester.pumpAndSettle();

    expect(
      find.text('Your session has expired. Please sign in again.'),
      findsOneWidget,
    );
  });
}
