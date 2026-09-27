import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:sure_mobile/services/budgets_service.dart';

import '../support/budget_fixtures.dart';

void main() {
  tearDown(ApiConfig.clearApiKeyAuth);

  test('list reads the requested page without fetching derived spending',
      () async {
    final service = BudgetsService(client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/budgets');
      expect(request.url.queryParameters, {'page': '2', 'per_page': '20'});
      expect(request.headers['Authorization'], 'Bearer token');
      return http.Response(jsonEncode(budgetPage(page: 2, totalPages: 3)), 200);
    }));
    final result = await service.getBudgets(accessToken: 'token', page: 2);
    expect(result.page, 2);
    expect(result.totalPages, 3);
    expect(result.items.single.amounts.spentMinor, isNull);
  });

  test('category list filters by budget and supports API key authentication',
      () async {
    ApiConfig.setApiKeyAuth('test-key');
    final service = BudgetsService(client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/budget_categories');
      expect(request.url.queryParameters['budget_id'], 'budget-1');
      expect(request.url.queryParameters['page'], '2');
      expect(request.headers['X-Api-Key'], 'test-key');
      expect(request.headers.containsKey('Authorization'), isFalse);
      return http.Response(
          jsonEncode(categoryPage(page: 2, totalPages: 2)), 200);
    }));
    final result = await service.getCategories(
        accessToken: 'test-key', budgetId: 'budget-1', page: 2);
    expect(result.items.single.name, 'Groceries');
    expect(result.items.single.amounts.spent, isNull);
  });

  test('show endpoints fetch server-calculated amounts and encode identifiers',
      () async {
    final paths = <String>[];
    final service = BudgetsService(client: MockClient((request) async {
      paths.add(request.url.toString());
      final payload = request.url.path.contains('budget_categories')
          ? categoryJson(detail: true)
          : budgetJson(detail: true);
      return http.Response(jsonEncode(payload), 200);
    }));
    final budget =
        await service.getBudget(accessToken: 'token', id: 'budget/1');
    final category =
        await service.getCategory(accessToken: 'token', id: 'category/1');
    expect(paths[0], contains('budgets/budget%2F1'));
    expect(paths[1], contains('budget_categories/category%2F1'));
    expect(budget.amounts.remainingMinor, -5000);
    expect(category.amounts.rolloverMinor, 5000);
  });

  for (final (status, error) in [
    (401, BudgetLoadError.unauthorized),
    (403, BudgetLoadError.forbidden),
    (404, BudgetLoadError.notFound),
    (500, BudgetLoadError.unavailable),
  ]) {
    test('maps HTTP $status without exposing response bodies', () async {
      final service = BudgetsService(
          client: MockClient(
              (_) async => http.Response('private server response', status)));
      await expectLater(
          service.getBudgets(accessToken: 'token'), throwsA(error));
    });
  }

  test('network failures and malformed success payloads are recoverable',
      () async {
    for (final body in ['<html>Login</html>', '{}', '{"budgets": []}']) {
      final service = BudgetsService(
          client: MockClient((_) async => http.Response(body, 200)));
      await expectLater(service.getBudgets(accessToken: 'token'),
          throwsA(BudgetLoadError.unavailable));
    }
    final service = BudgetsService(
        client: MockClient((_) async => throw http.ClientException('offline')));
    await expectLater(service.getBudgets(accessToken: 'token'),
        throwsA(BudgetLoadError.unavailable));
  });
}
