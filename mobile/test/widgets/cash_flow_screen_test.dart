import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/l10n/app_localizations.dart';
import 'package:sure_mobile/models/cash_flow.dart';
import 'package:sure_mobile/providers/privacy_provider.dart';
import 'package:sure_mobile/screens/cash_flow_category_transactions_screen.dart';
import 'package:sure_mobile/screens/cash_flow_screen.dart';
import 'package:sure_mobile/screens/more_screen.dart';
import 'package:sure_mobile/services/cash_flow_service.dart';
import 'package:sure_mobile/services/preferences_service.dart';
import 'package:sure_mobile/services/transactions_service.dart';
import 'package:sure_mobile/theme/sure_theme.dart';
import 'package:sure_mobile/widgets/cash_flow_donut_chart.dart';
import 'package:sure_mobile/widgets/sure_segmented_control.dart';

import '../support/cash_flow_fixture.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
  });

  final requests = <Uri>[];
  final settingsRequests = <Uri>[];

  // Answers `GET /api/v1/family_settings` (not recorded in [requests]).
  http.Response? familySettings(http.Request request,
      {int monthStartDay = 1, int status = 200}) {
    if (request.url.path != '/api/v1/family_settings') return null;
    settingsRequests.add(request.url);
    return http.Response('{"month_start_day":$monthStartDay}', status);
  }

  CashFlowService service({
    int status = 200,
    int monthStartDay = 1,
    int settingsStatus = 200,
  }) =>
      CashFlowService(
        client: MockClient((request) async {
          final settings = familySettings(request,
              monthStartDay: monthStartDay, status: settingsStatus);
          if (settings != null) return settings;
          requests.add(request.url);
          return http.Response(
            status == 200 ? cashFlowSankeyFixture : '{}',
            status,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

  // A tall phone-width surface so the whole report is laid out on screen.
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget harness({
    required CashFlowService cashFlowService,
    bool hidden = false,
    DateTime Function()? clock,
    AccessTokenLoader? accessTokenLoader,
    Future<void> Function(BuildContext context)? onUnauthorized,
  }) {
    return ChangeNotifierProvider<PrivacyProvider>.value(
      value: PrivacyProvider(initialHidden: hidden),
      child: MaterialApp(
        theme: SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CashFlowScreen(
          service: cashFlowService,
          transactionsService: TransactionsService(
            client: MockClient((request) async {
              requests.add(request.url);
              return http.Response(
                '{"transactions":[{"id":"t1","account":{"id":"a1"},'
                '"name":"Corner Market","date":"2026-10-03",'
                '"amount":"\$42.10","currency":"USD",'
                '"classification":"expense",'
                '"category":{"id":"cat_groceries","name":"Groceries"}}],'
                '"pagination":{"page":1,"per_page":50,"total_count":1,'
                '"total_pages":1}}',
                200,
              );
            }),
          ),
          accessTokenLoader: accessTokenLoader ?? (_) async => 'token',
          clock: clock ?? () => DateTime(2026, 10, 19),
          onUnauthorized: onUnauthorized,
        ),
      ),
    );
  }

  setUp(() {
    requests.clear();
    settingsRequests.clear();
  });

  testWidgets('shows income, expenses, net savings and ranked expenses',
      (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    expect(requests.single.queryParameters['start_date'], '2026-10-01');
    expect(requests.single.queryParameters['end_date'], '2026-10-19');

    expect(find.text(r'$3,500.00'), findsOneWidget); // net savings
    expect(find.text(r'$5,000.00'), findsOneWidget); // income
    expect(find.text('70.0% savings rate'), findsOneWidget);
    expect(find.byKey(const ValueKey('cashFlowDonut')), findsOneWidget);

    expect(find.text('Rent'), findsOneWidget);
    expect(find.text('66.7% of expenses'), findsOneWidget);
    // Ranked largest first.
    final rentY = tester.getTopLeft(find.text('Rent')).dy;
    final foodY = tester.getTopLeft(find.text('Food & Drink')).dy;
    expect(rentY, lessThan(foodY));
  });

  testWidgets('switches to income by category', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(SureSegmentedControl<CashFlowSide>),
      matching: find.text('Income'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Income by category'.toUpperCase()), findsOneWidget);
    expect(find.text('Salary'), findsOneWidget);
    expect(find.text('90.0% of income'), findsOneWidget);
  });

  testWidgets('changing the period requests that range', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_lastMonth')));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['start_date'], '2026-09-01');
    expect(requests.last.queryParameters['end_date'], '2026-09-30');

    // Returning to a loaded period reuses the report.
    final count = requests.length;
    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_currentMonth')));
    await tester.pumpAndSettle();
    expect(requests.length, count);
  });

  testWidgets('privacy mode masks amounts and shares', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service(), hidden: true));
    await tester.pumpAndSettle();

    expect(find.text(r'$3,500.00'), findsNothing);
    expect(find.text('66.7% of expenses'), findsNothing);
    expect(find.text('••••% of expenses'), findsWidgets);
    expect(find.text(r'$••••'), findsWidgets);
  });

  testWidgets('tapping a category opens its transactions', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Food & Drink'));
    await tester.pumpAndSettle();

    final screen = tester.widget<CashFlowCategoryTransactionsScreen>(
      find.byType(CashFlowCategoryTransactionsScreen),
    );
    expect(
        screen.category.transactionCategoryIds, ['cat_food', 'cat_groceries']);
    expect(
      screen.range,
      CashFlowDateRange(DateTime(2026, 10, 1), DateTime(2026, 10, 19)),
    );

    final txRequest = requests.last;
    expect(txRequest.path, '/api/v1/transactions');
    expect(txRequest.queryParametersAll['category_ids[]'],
        ['cat_food', 'cat_groceries']);
    expect(txRequest.queryParameters['start_date'], '2026-10-01');
    expect(find.text('Corner Market'), findsOneWidget);
    expect(find.text('-\$42.10'), findsOneWidget);
    expect(find.textContaining('Groceries'), findsOneWidget);
  });

  testWidgets('uncategorized is listed but not tappable', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uncategorized'));
    await tester.pumpAndSettle();
    expect(find.byType(CashFlowCategoryTransactionsScreen), findsNothing);
  });

  testWidgets('shows an error state with retry when loading fails',
      (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service(status: 500)));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load cash flow"), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('Try Again reloads the report', (tester) async {
    usePhoneSurface(tester);
    var calls = 0;
    final recovering = CashFlowService(
      client: MockClient((request) async {
        final settings = familySettings(request);
        if (settings != null) return settings;
        calls++;
        return calls == 1
            ? http.Response('{}', 500)
            : http.Response(cashFlowSankeyFixture, 200);
      }),
    );
    await tester.pumpWidget(harness(cashFlowService: recovering));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text("Couldn't load cash flow"), findsOneWidget);

    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text("Couldn't load cash flow"), findsNothing);
    expect(find.text('Try Again'), findsNothing);
    expect(find.text(r'$3,500.00'), findsOneWidget);
  });

  testWidgets('keeps the last report, marked outdated, when a refresh fails',
      (tester) async {
    usePhoneSurface(tester);
    var calls = 0;
    final flaky = CashFlowService(
      client: MockClient((request) async {
        final settings = familySettings(request);
        if (settings != null) return settings;
        calls++;
        return calls == 1
            ? http.Response(cashFlowSankeyFixture, 200)
            : http.Response('{}', 503);
      }),
    );
    await tester.pumpWidget(harness(cashFlowService: flaky));
    await tester.pumpAndSettle();
    expect(find.text('Outdated'), findsNothing);

    await tester.fling(find.text('Rent'), const Offset(0, 600), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('Outdated'), findsOneWidget);
    expect(find.text(r'$3,500.00'), findsOneWidget);
  });

  testWidgets('refetches a cached period once its date range moves',
      (tester) async {
    usePhoneSurface(tester);
    var today = DateTime(2026, 10, 31);
    await tester
        .pumpWidget(harness(cashFlowService: service(), clock: () => today));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['start_date'], '2026-10-01');

    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_lastMonth')));
    await tester.pumpAndSettle();

    // The date changes while the screen stays open.
    today = DateTime(2026, 11, 1);
    final count = requests.length;
    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_currentMonth')));
    await tester.pumpAndSettle();

    expect(requests.length, count + 1);
    expect(requests.last.queryParameters['start_date'], '2026-11-01');
    expect(requests.last.queryParameters['end_date'], '2026-11-01');
  });

  testWidgets('shows the error state when the access token loader throws',
      (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(
      cashFlowService: service(),
      accessTokenLoader: (_) async => throw Exception('storage failed'),
    ));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load cash flow"), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('More screen links to Cash Flow', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(ChangeNotifierProvider<PrivacyProvider>.value(
      value: PrivacyProvider(initialHidden: false),
      child: MaterialApp(
        theme: SureTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MoreScreen(),
      ),
    ));
    expect(find.text('Cash Flow'), findsOneWidget);
    expect(
        find.text('Income, spending and savings by category'), findsOneWidget);

    await tester.tap(find.text('Cash Flow'));
    await tester.pumpAndSettle();

    expect(find.byType(CashFlowScreen), findsOneWidget);
    expect(find.byType(MoreScreen), findsNothing);
  });

  testWidgets('This month and Last month follow the family month start day',
      (tester) async {
    usePhoneSurface(tester);
    await tester
        .pumpWidget(harness(cashFlowService: service(monthStartDay: 15)));
    await tester.pumpAndSettle();

    expect(settingsRequests, hasLength(1));
    expect(requests.single.queryParameters['start_date'], '2026-10-15');
    expect(requests.single.queryParameters['end_date'], '2026-11-14');

    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_lastMonth')));
    await tester.pumpAndSettle();

    expect(requests.last.queryParameters['start_date'], '2026-09-15');
    expect(requests.last.queryParameters['end_date'], '2026-10-14');
    // The setting is looked up once per screen.
    expect(settingsRequests, hasLength(1));
  });

  testWidgets('falls back to calendar months when family settings fail',
      (tester) async {
    usePhoneSurface(tester);
    await tester
        .pumpWidget(harness(cashFlowService: service(settingsStatus: 500)));
    await tester.pumpAndSettle();

    expect(requests.single.queryParameters['start_date'], '2026-10-01');
    expect(requests.single.queryParameters['end_date'], '2026-10-19');
    expect(find.text(r'$3,500.00'), findsOneWidget);
  });

  testWidgets('a 401 from the report logs the session out', (tester) async {
    usePhoneSurface(tester);
    var logouts = 0;
    await tester.pumpWidget(harness(
      cashFlowService: service(status: 401),
      onUnauthorized: (_) async => logouts++,
    ));
    await tester.pumpAndSettle();

    expect(logouts, 1);
  });

  testWidgets('a 401 from family settings logs out without loading the report',
      (tester) async {
    usePhoneSurface(tester);
    var logouts = 0;
    await tester.pumpWidget(harness(
      cashFlowService: service(settingsStatus: 401),
      onUnauthorized: (_) async => logouts++,
    ));
    await tester.pumpAndSettle();

    expect(logouts, 1);
    expect(requests, isEmpty);
  });

  testWidgets('returning to a period reuses its in-flight request',
      (tester) async {
    usePhoneSurface(tester);
    final pending = <String, Completer<http.Response>>{};
    final slow = CashFlowService(
      client: MockClient((request) {
        final settings = familySettings(request);
        if (settings != null) return Future.value(settings);
        requests.add(request.url);
        final completer = Completer<http.Response>();
        pending[request.url.queryParameters['start_date']!] = completer;
        return completer.future;
      }),
    );
    await tester.pumpWidget(harness(cashFlowService: slow));
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(1)); // This month, 2026-10-01

    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_lastMonth')));
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(2));

    // Back to This month while its first request is still running.
    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_currentMonth')));
    await tester.pump();
    await tester.pump();
    expect(requests, hasLength(2));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    pending['2026-10-01']!.complete(http.Response(cashFlowSankeyFixture, 200));
    await tester.pumpAndSettle();
    expect(find.text(r'$3,500.00'), findsOneWidget);

    pending['2026-09-01']!.complete(http.Response('{}', 500));
    await tester.pumpAndSettle();
    expect(find.text(r'$3,500.00'), findsOneWidget);
  });

  testWidgets('hides a cached report for an old range while it reloads',
      (tester) async {
    usePhoneSurface(tester);
    var today = DateTime(2026, 10, 31);
    final next = <Completer<http.Response>>[];
    final service = CashFlowService(
      client: MockClient((request) {
        final settings = familySettings(request);
        if (settings != null) return Future.value(settings);
        requests.add(request.url);
        if (next.isNotEmpty) return next.last.future;
        return Future.value(http.Response(cashFlowSankeyFixture, 200));
      }),
    );
    await tester
        .pumpWidget(harness(cashFlowService: service, clock: () => today));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_lastMonth')));
    await tester.pumpAndSettle();

    today = DateTime(2026, 11, 1);
    next.add(Completer<http.Response>());
    await tester.tap(find.byKey(const ValueKey('cashFlowPeriod_currentMonth')));
    await tester.pump();
    await tester.pump();

    // October's report is not shown (or tappable) while November loads.
    expect(find.text('Rent'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    next.last.complete(http.Response(cashFlowSankeyFixture, 200));
    await tester.pumpAndSettle();
    expect(find.text('Rent'), findsOneWidget);
  });

  testWidgets('privacy mode hides the donut slices', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service(), hidden: true));
    await tester.pumpAndSettle();

    final donut = tester.widget<CashFlowDonutChart>(
        find.byKey(const ValueKey('cashFlowDonut')));
    expect(donut.hidden, isTrue);
  });

  testWidgets('the donut shows its slices outside privacy mode',
      (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(harness(cashFlowService: service()));
    await tester.pumpAndSettle();

    final donut = tester.widget<CashFlowDonutChart>(
        find.byKey(const ValueKey('cashFlowDonut')));
    expect(donut.hidden, isFalse);
    expect(donut.segments, isNotEmpty);
  });
}
