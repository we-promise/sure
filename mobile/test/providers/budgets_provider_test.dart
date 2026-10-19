import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sure_mobile/providers/budgets_provider.dart';
import 'package:sure_mobile/services/budgets_service.dart';

import '../support/budget_fixtures.dart';

void main() {
  DateTime clock() => DateTime(2026, 10, 19);

  BudgetsProvider buildProvider({
    List<Map<String, dynamic>>? budgets,
    List<Map<String, dynamic>>? categories,
    List<http.Request>? log,
    int statusCode = 200,
    bool Function()? isOffline,
  }) {
    return BudgetsProvider(
      service: BudgetsService(
        client: budgetsMockClient(
          budgets: budgets,
          categories: categories,
          log: log,
          statusCode: statusCode,
        ),
      ),
      clock: clock,
      isOffline: isOffline,
    );
  }

  test('starts on the current month and cannot go past it', () {
    final provider = buildProvider();
    expect(provider.month, DateTime(2026, 10));
    expect(provider.canGoNext, isFalse);

    provider.nextMonth();
    expect(provider.month, DateTime(2026, 10));

    provider.previousMonth();
    expect(provider.month, DateTime(2026, 9));
    expect(provider.canGoNext, isTrue);
  });

  test('assembles a month from the budget and category endpoints', () async {
    final log = <http.Request>[];
    final provider = buildProvider(log: log);

    await provider.loadMonth(accessToken: 'token');

    expect(provider.error, isNull);
    expect(provider.budget?.actualSpending, r'$1,500.00');
    expect(provider.categories, hasLength(5));
    expect(provider.categories.every((c) => c.hasDerivedAmounts), isTrue);

    // Gifts (no budget, no spending) is hidden; Food keeps both children.
    final groups = provider.visibleGroups;
    expect(groups.map((g) => g.parent.name), ['Food', 'Transport']);
    expect(groups.first.children.map((c) => c.name), [
      'Groceries',
      'Restaurants',
    ]);
    expect(provider.overBudgetCount, 1);

    // list + show budget + list categories + one show per category
    expect(log, hasLength(3 + 5));
    expect(log.first.url.queryParameters['start_date'], '2026-10-01');
    expect(log.first.url.queryParameters['end_date'], '2026-11-30');
  });

  test('uses the in-memory copy unless forced', () async {
    final log = <http.Request>[];
    final provider = buildProvider(log: log);

    await provider.loadMonth(accessToken: 'token');
    final first = log.length;
    await provider.loadMonth(accessToken: 'token');
    expect(log.length, first);

    await provider.loadMonth(accessToken: 'token', forceRefresh: true);
    expect(log.length, first * 2);
  });

  test('matches a custom month start budget by its start month', () async {
    final provider = buildProvider(
      budgets: [
        budgetJson(
          id: 'budget_sep',
          startDate: '2026-09-15',
          endDate: '2026-10-14',
        ),
        budgetJson(
          id: 'budget_oct',
          startDate: '2026-10-15',
          endDate: '2026-11-14',
          name: 'Oct 15 - Nov 14, 2026',
        ),
      ],
    );

    await provider.loadMonth(accessToken: 'token');
    expect(provider.monthBudgets.map((b) => b.id), ['budget_oct']);
    expect(provider.budget?.name, 'Oct 15 - Nov 14, 2026');
  });

  test('a month with no budget is empty, not an error', () async {
    final provider = buildProvider(budgets: []);
    await provider.loadMonth(accessToken: 'token');

    expect(provider.error, isNull);
    expect(provider.hasLoadedMonth, isTrue);
    expect(provider.budget, isNull);
  });

  test('switches between several budgets in the same month', () async {
    final provider = buildProvider(
      budgets: [
        budgetJson(id: 'budget_oct'),
        budgetJson(id: 'budget_oct_personal', actualCents: 1000),
      ],
    );

    await provider.loadMonth(accessToken: 'token');
    expect(provider.monthBudgets, hasLength(2));
    expect(provider.budget?.id, 'budget_oct');

    await provider.selectBudget(
      accessToken: 'token',
      budgetId: 'budget_oct_personal',
    );
    expect(provider.budget?.id, 'budget_oct_personal');
    expect(provider.budget?.actualSpending, r'$10.00');
  });

  test('401 surfaces as unauthorized', () async {
    final provider = buildProvider(statusCode: 401);
    await provider.loadMonth(accessToken: 'token');
    expect(provider.error, BudgetsLoadError.unauthorized);
  });

  test('offline without a loaded month reports offline', () async {
    final log = <http.Request>[];
    final provider = buildProvider(log: log, isOffline: () => true);
    await provider.loadMonth(accessToken: 'token');

    expect(provider.error, BudgetsLoadError.offline);
    expect(log, isEmpty);
  });

  test('offline keeps showing a month loaded earlier', () async {
    var offline = false;
    final provider = buildProvider(isOffline: () => offline);
    await provider.loadMonth(accessToken: 'token');

    offline = true;
    await provider.loadMonth(accessToken: 'token', forceRefresh: true);

    expect(provider.error, isNull);
    expect(provider.showingCachedWhileOffline, isTrue);
    expect(provider.budget?.id, 'budget_oct');
  });
}
