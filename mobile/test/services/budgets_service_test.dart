import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/models/budget.dart';
import 'package:sure_mobile/services/budgets_service.dart';
import 'package:sure_mobile/services/transactions_service.dart';

import '../support/budget_fixtures.dart';

void main() {
  group('BudgetsService', () {
    test('lists budgets with date filters', () async {
      final requests = <http.Request>[];
      final service = BudgetsService(
        client: budgetsMockClient(log: requests),
      );

      final result = await service.getBudgets(
        accessToken: 'token',
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 11, 30),
        perPage: 100,
      );

      expect(result['success'], isTrue);
      final budgets = result['budgets'] as List<Budget>;
      expect(budgets.single.id, 'budget_oct');
      expect(budgets.single.hasDerivedAmounts, isFalse);

      final url = requests.single.url;
      expect(url.path, '/api/v1/budgets');
      expect(url.queryParameters['start_date'], '2026-10-01');
      expect(url.queryParameters['end_date'], '2026-11-30');
      expect(url.queryParameters['per_page'], '100');
    });

    test('fetches a budget with derived amounts', () async {
      final service = BudgetsService(client: budgetsMockClient());
      final result = await service.getBudget(
        accessToken: 'token',
        id: 'budget_oct',
      );

      expect(result['success'], isTrue);
      final budget = result['budget'] as Budget;
      expect(budget.actualSpending, r'$1,500.00');
    });

    test('lists budget categories for a budget', () async {
      final requests = <http.Request>[];
      final service = BudgetsService(
        client: budgetsMockClient(log: requests),
      );

      final result = await service.getBudgetCategories(
        accessToken: 'token',
        budgetId: 'budget_oct',
      );

      expect(result['success'], isTrue);
      final categories = result['budget_categories'] as List<BudgetCategory>;
      expect(categories, hasLength(5));
      expect(categories.first.hasDerivedAmounts, isFalse);
      expect(requests.single.url.queryParameters['budget_id'], 'budget_oct');
    });

    test('fetches one budget category with actual spending', () async {
      final service = BudgetsService(client: budgetsMockClient());
      final result = await service.getBudgetCategory(
        accessToken: 'token',
        id: 'bc_groceries',
      );

      final bc = result['budget_category'] as BudgetCategory;
      expect(bc.actualSpendingCents, 52000);
      expect(bc.availableToSpend, r'-$120.00');
    });

    test('maps 401 to unauthorized', () async {
      final service = BudgetsService(
        client: budgetsMockClient(statusCode: 401),
      );
      final result = await service.getBudgets(accessToken: 'token');
      expect(result, {'success': false, 'error': 'unauthorized'});
    });

    test('reports server error message', () async {
      final service = BudgetsService(
        client: budgetsMockClient(statusCode: 500),
      );
      final result = await service.getBudget(accessToken: 'token', id: 'x');
      expect(result['success'], isFalse);
      expect(result['error'], 'nope');
    });
  });

  test('TransactionsService filters by categories and date range', () async {
    late Uri captured;
    final service = TransactionsService(
      client: MockClient((request) async {
        captured = request.url;
        return http.Response(
          '{"transactions":[],"pagination":{"page":1,"total_pages":1}}',
          200,
        );
      }),
    );

    final result = await service.getTransactions(
      accessToken: 'token',
      categoryIds: ['cat_food', 'cat_groceries'],
      startDate: '2026-10-01',
      endDate: '2026-10-31',
      page: 1,
      perPage: 50,
    );

    expect(result['success'], isTrue);
    expect(captured.queryParametersAll['category_ids[]'], [
      'cat_food',
      'cat_groceries',
    ]);
    expect(captured.queryParameters['start_date'], '2026-10-01');
    expect(captured.queryParameters['end_date'], '2026-10-31');
    expect(captured.queryParameters.containsKey('account_id'), isFalse);
  });
}
