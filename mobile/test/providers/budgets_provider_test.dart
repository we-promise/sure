import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    DateTime Function()? now,
    http.Client? client,
  }) {
    return BudgetsProvider(
      service: BudgetsService(
        client: client ??
            budgetsMockClient(
              budgets: budgets,
              categories: categories,
              log: log,
              statusCode: statusCode,
            ),
      ),
      clock: now ?? clock,
      isOffline: isOffline,
    );
  }

  test('can navigate up to two years past the current month', () {
    final provider = buildProvider();
    expect(provider.month, DateTime(2026, 10));
    expect(provider.canGoNext, isTrue);

    provider.nextMonth();
    expect(provider.month, DateTime(2026, 11));

    for (var i = 0; i < 30; i++) {
      provider.nextMonth();
    }
    expect(provider.month, DateTime(2028, 10));
    expect(provider.canGoNext, isFalse);

    provider.previousMonth();
    expect(provider.month, DateTime(2028, 9));
    expect(provider.canGoNext, isTrue);
  });

  test('opens on the custom period that contains today', () async {
    final provider = buildProvider(
      now: () => DateTime(2026, 10, 10),
      budgets: [
        budgetJson(
          id: 'budget_sep',
          startDate: '2026-09-15',
          endDate: '2026-10-14',
          name: 'Sep 15 - Oct 14, 2026',
        ),
      ],
    );

    await provider.loadMonth(accessToken: 'token');

    expect(provider.month, DateTime(2026, 9));
    expect(provider.budget?.id, 'budget_sep');
    // Navigation is bounded by the current period, not the calendar month.
    for (var i = 0; i < 30; i++) {
      provider.nextMonth();
    }
    expect(provider.month, DateTime(2028, 9));
  });

  test("opens on the server's current period, not the device date",
      () async {
    // Device is already on April 1 (Tokyo); the family is still on March 31.
    final provider = buildProvider(
      now: () => DateTime(2027, 4, 1),
      budgets: [
        budgetJson(
          id: 'budget_apr',
          startDate: '2027-04-01',
          endDate: '2027-04-30',
          name: 'April 2027',
          current: false,
        ),
        budgetJson(
          id: 'budget_mar',
          startDate: '2027-03-01',
          endDate: '2027-03-31',
          name: 'March 2027',
        ),
      ],
    );

    await provider.loadMonth(accessToken: 'token');

    expect(provider.month, DateTime(2027, 3));
    expect(provider.budget?.id, 'budget_mar');
  });

  test('changing month drops the previous load\'s spinner and error',
      () async {
    final inner = budgetsMockHandler();
    final gate = Completer<void>();
    var gated = false;
    final provider = buildProvider(
      client: MockClient((request) async {
        if (gated && request.url.path.endsWith('/budgets/budget_oct')) {
          await gate.future;
          return http.Response('{"error":"boom"}', 500);
        }
        return inner(request);
      }),
    );
    await provider.loadMonth(accessToken: 'token');

    gated = true;
    final refresh = provider.loadMonth(accessToken: 'token', forceRefresh: true);
    await Future<void>.delayed(Duration.zero);
    expect(provider.isLoading, isTrue);

    provider.previousMonth();
    expect(provider.isLoading, isFalse);

    gate.complete();
    await refresh;
    expect(provider.month, DateTime(2026, 9));
    expect(provider.isLoading, isFalse);
    expect(provider.error, isNull);
  });

  test('a budget list is only reused for the month it was loaded for',
      () async {
    final inner = budgetsMockHandler(
      budgets: [
        budgetJson(
          id: 'budget_sep',
          startDate: '2026-09-15',
          endDate: '2026-10-14',
          name: 'Sep 15 - Oct 14, 2026',
        ),
        budgetJson(
          id: 'budget_oct',
          startDate: '2026-10-15',
          endDate: '2026-11-14',
          name: 'Oct 15 - Nov 14, 2026',
          current: false,
        ),
        budgetJson(
          id: 'budget_oct_personal',
          startDate: '2026-10-15',
          endDate: '2026-11-14',
          name: 'Oct 15 - Nov 14, 2026',
          current: false,
        ),
      ],
    );
    var failFirst = true;
    final provider = buildProvider(
      now: () => DateTime(2026, 10, 10),
      client: MockClient((request) async {
        if (failFirst) {
          failFirst = false; // the current-period lookup fails once
          return http.Response('{"error":"boom"}', 500);
        }
        return inner(request);
      }),
    );

    await provider.loadMonth(accessToken: 'token');
    expect(provider.month, DateTime(2026, 10));
    expect(provider.monthBudgets.map((b) => b.id),
        ['budget_oct', 'budget_oct_personal']);

    // Selecting retries the period lookup, which moves to September.
    await provider.selectBudget(
      accessToken: 'token',
      budgetId: 'budget_oct_personal',
    );

    expect(provider.month, DateTime(2026, 9));
    expect(provider.monthBudgets.map((b) => b.id), ['budget_sep']);
    expect(provider.budget?.id, 'budget_sep');
  });

  test('more category pages than the safety stop fail the month', () async {
    final inner = budgetsMockHandler();
    final provider = buildProvider(
      client: MockClient((request) async {
        final segments = request.url.pathSegments;
        if (segments.length == 3 && segments[2] == 'budget_categories') {
          return http.Response(
            '{"budget_categories":[],"pagination":'
            '{"page":1,"per_page":100,"total_count":100000,"total_pages":1000}}',
            200,
          );
        }
        return inner(request);
      }),
    );

    await provider.loadMonth(accessToken: 'token');

    expect(provider.error, BudgetsLoadError.failed);
    expect(provider.hasLoadedMonth, isFalse);
  });

  test('a failed refresh keeps the month already loaded', () async {
    final inner = budgetsMockHandler();
    var fail = false;
    final provider = buildProvider(
      client: MockClient((request) async {
        if (fail) throw http.ClientException('connection reset');
        return inner(request);
      }),
    );

    await provider.loadMonth(accessToken: 'token');
    expect(provider.error, isNull);
    expect(provider.refreshFailed, isFalse);

    fail = true;
    await provider.loadMonth(accessToken: 'token', forceRefresh: true);

    expect(provider.error, BudgetsLoadError.failed);
    expect(provider.hasLoadedMonth, isTrue);
    expect(provider.refreshFailed, isTrue);
    expect(provider.categories, isNotEmpty);
  });

  test('a load that finishes after dispose does not notify', () async {
    final inner = budgetsMockHandler();
    final gate = Completer<void>();
    final provider = buildProvider(
      client: MockClient((request) async {
        await gate.future;
        return inner(request);
      }),
    );

    final load = provider.loadMonth(accessToken: 'token');
    await Future<void>.delayed(Duration.zero);
    provider.dispose();
    gate.complete();
    await load; // would throw "used after being disposed" without the guard
  });

  test('a network failure on a category line fails the month uncached',
      () async {
    final inner = budgetsMockHandler();
    var failFood = true;
    final provider = buildProvider(
      client: MockClient((request) async {
        if (failFood && request.url.path.endsWith('/bc_food')) {
          throw http.ClientException('connection reset');
        }
        return inner(request);
      }),
    );

    await provider.loadMonth(accessToken: 'token');
    expect(provider.error, BudgetsLoadError.failed);
    expect(provider.hasLoadedMonth, isFalse);

    failFood = false;
    await provider.loadMonth(accessToken: 'token');
    expect(provider.error, isNull);
    expect(provider.categories.every((c) => c.hasDerivedAmounts), isTrue);
  });

  test('a missing category line keeps its budgeted amount', () async {
    final inner = budgetsMockHandler();
    final provider = buildProvider(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/bc_transport')) {
          return http.Response('{"error":"not_found"}', 404);
        }
        return inner(request);
      }),
    );
    await provider.loadMonth(accessToken: 'token');

    expect(provider.error, isNull);
    final transport =
        provider.categories.firstWhere((c) => c.name == 'Transport');
    expect(transport.hasDerivedAmounts, isFalse);
    expect(transport.budgetedSpendingCents, 30000);
  });

  test('shows the loading state while the current period resolves', () async {
    final inner = budgetsMockHandler();
    final gate = Completer<void>();
    var calls = 0;
    final provider = buildProvider(
      client: MockClient((request) async {
        if (calls++ == 0) await gate.future;
        return inner(request);
      }),
    );

    final load = provider.loadMonth(accessToken: 'token');
    await Future<void>.delayed(Duration.zero);
    expect(provider.isLoading, isTrue);
    expect(provider.hasLoadedMonth, isFalse);

    gate.complete();
    await load;
    expect(provider.isLoading, isFalse);
    expect(provider.hasLoadedMonth, isTrue);
  });

  test('returning to a cached month clears a pending load', () async {
    final inner = budgetsMockHandler();
    final gate = Completer<void>();
    var gateSeptember = false;
    final provider = buildProvider(
      client: MockClient((request) async {
        if (gateSeptember &&
            request.url.queryParameters['start_date'] == '2026-09-01') {
          await gate.future;
        }
        return inner(request);
      }),
    );
    await provider.loadMonth(accessToken: 'token');

    gateSeptember = true;
    provider.previousMonth();
    final september = provider.loadMonth(accessToken: 'token');
    await Future<void>.delayed(Duration.zero);
    expect(provider.isLoading, isTrue);

    provider.nextMonth();
    await provider.loadMonth(accessToken: 'token');
    expect(provider.isLoading, isFalse);
    expect(provider.budget?.id, 'budget_oct');

    gate.complete();
    await september;
    expect(provider.isLoading, isFalse);
  });

  test('markUnauthorized shows the session-expired state', () {
    final provider = buildProvider();
    provider.markUnauthorized();
    expect(provider.error, BudgetsLoadError.unauthorized);
    expect(provider.isLoading, isFalse);
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

    // current period lookup, then list + show budget + list categories +
    // one show per category
    expect(log, hasLength(1 + 3 + 5));
    expect(log.first.url.queryParameters['start_date'], '2026-09-01');
    expect(log.first.url.queryParameters['end_date'], '2026-11-30');
    expect(log[1].url.queryParameters['start_date'], '2026-10-01');
    expect(log[1].url.queryParameters['end_date'], '2026-11-30');
  });

  test('an uninitialized budget lists every category', () async {
    final provider = buildProvider(budgets: [budgetJson(initialized: false)]);

    await provider.loadMonth(accessToken: 'token');

    expect(provider.showsAllCategories, isTrue);
    expect(provider.visibleGroups.map((g) => g.parent.name),
        containsAll(['Food', 'Transport', 'Gifts']));
  });

  test('uses the in-memory copy unless forced', () async {
    final log = <http.Request>[];
    final provider = buildProvider(log: log);

    await provider.loadMonth(accessToken: 'token');
    final first = log.length;
    await provider.loadMonth(accessToken: 'token');
    expect(log.length, first);

    await provider.loadMonth(accessToken: 'token', forceRefresh: true);
    // The current period is looked up only once.
    expect(log.length - first, 3 + 5);
  });

  test('matches a custom month start budget by its start month', () async {
    final provider = buildProvider(
      budgets: [
        budgetJson(
          id: 'budget_sep',
          startDate: '2026-09-15',
          endDate: '2026-10-14',
          current: false, // today (Oct 19) is in the October period
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

  test('switching budgets does not refetch the month list', () async {
    final log = <http.Request>[];
    final provider = buildProvider(
      log: log,
      budgets: [
        budgetJson(id: 'budget_oct'),
        budgetJson(id: 'budget_oct_personal', actualCents: 1000),
      ],
    );
    await provider.loadMonth(accessToken: 'token');
    log.clear();

    await provider.selectBudget(
      accessToken: 'token',
      budgetId: 'budget_oct_personal',
    );
    expect(provider.budget?.id, 'budget_oct_personal');
    expect(provider.monthBudgets, hasLength(2));
    expect(log.where((r) => r.url.path.endsWith('/api/v1/budgets')), isEmpty);
    expect(log, isNotEmpty);
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
