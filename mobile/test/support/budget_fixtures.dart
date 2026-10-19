import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// JSON fixtures shaped like the `/api/v1/budgets` and
/// `/api/v1/budget_categories` jbuilder views, plus a [MockClient] that routes
/// requests to them.

Map<String, dynamic> budgetJson({
  String id = 'budget_oct',
  String startDate = '2026-10-01',
  String endDate = '2026-10-31',
  String name = 'October 2026',
  bool initialized = true,
  bool withDerived = true,
  int budgetedCents = 200000,
  int actualCents = 150000,
  int availableCents = 50000,
}) {
  return {
    'id': id,
    'start_date': startDate,
    'end_date': endDate,
    'name': name,
    'currency': 'USD',
    'initialized': initialized,
    'current': true,
    'budgeted_spending': initialized ? _usd(budgetedCents) : null,
    'budgeted_spending_cents': initialized ? budgetedCents : null,
    'expected_income': r'$5,000.00',
    'expected_income_cents': 500000,
    'allocated_spending': _usd(budgetedCents),
    'allocated_spending_cents': budgetedCents,
    if (withDerived) ...{
      'actual_spending': _usd(actualCents),
      'actual_spending_cents': actualCents,
      'actual_income': r'$5,200.00',
      'actual_income_cents': 520000,
      'available_to_spend': _usd(availableCents),
      'available_to_spend_cents': availableCents,
      'available_to_allocate': r'$0.00',
      'available_to_allocate_cents': 0,
    },
    'created_at': '2026-10-01T00:00:00Z',
    'updated_at': '2026-10-01T00:00:00Z',
  };
}

Map<String, dynamic> budgetCategoryJson({
  required String id,
  required String categoryId,
  required String name,
  String budgetId = 'budget_oct',
  String? parentId,
  int budgetedCents = 0,
  int? displayBudgetedCents,
  int actualCents = 0,
  int rolledOverCents = 0,
  int? availableCents,
  bool inheritsParent = false,
  bool withDerived = true,
  String color = '#e99537',
}) {
  final display = displayBudgetedCents ?? budgetedCents;
  final available =
      availableCents ?? (budgetedCents + rolledOverCents - actualCents);
  return {
    'id': id,
    'budget_id': budgetId,
    'currency': 'USD',
    'subcategory': parentId != null,
    'inherits_parent_budget': inheritsParent,
    'rollover_enabled': rolledOverCents > 0,
    'budgeted_spending': _usd(budgetedCents),
    'budgeted_spending_cents': budgetedCents,
    'display_budgeted_spending': _usd(display),
    'display_budgeted_spending_cents': display,
    if (withDerived) ...{
      'actual_spending': _usd(actualCents),
      'actual_spending_cents': actualCents,
      'rolled_over_amount': _usd(rolledOverCents),
      'rolled_over_amount_cents': rolledOverCents,
      'available_to_spend': _usd(available),
      'available_to_spend_cents': available,
    },
    'category': {
      'id': categoryId,
      'name': name,
      'color': color,
      'lucide_icon': 'shapes',
      'parent_id': parentId,
    },
    'created_at': '2026-10-01T00:00:00Z',
    'updated_at': '2026-10-01T00:00:00Z',
  };
}

/// A month with a parent (Food) and two subcategories (Groceries with its own
/// limit and over budget, Restaurants sharing Food's budget), plus Transport
/// (on track) and Gifts (no budget, no spending — hidden).
List<Map<String, dynamic>> octoberCategories() => [
      budgetCategoryJson(
        id: 'bc_food',
        categoryId: 'cat_food',
        name: 'Food',
        budgetedCents: 80000,
        actualCents: 76000,
      ),
      budgetCategoryJson(
        id: 'bc_gifts',
        categoryId: 'cat_gifts',
        name: 'Gifts',
      ),
      budgetCategoryJson(
        id: 'bc_groceries',
        categoryId: 'cat_groceries',
        name: 'Groceries',
        parentId: 'cat_food',
        budgetedCents: 40000,
        actualCents: 52000,
      ),
      budgetCategoryJson(
        id: 'bc_restaurants',
        categoryId: 'cat_restaurants',
        name: 'Restaurants',
        parentId: 'cat_food',
        inheritsParent: true,
        displayBudgetedCents: 80000,
        actualCents: 24000,
        availableCents: 0,
      ),
      budgetCategoryJson(
        id: 'bc_transport',
        categoryId: 'cat_transport',
        name: 'Transport',
        budgetedCents: 30000,
        actualCents: 12000,
        rolledOverCents: 5000,
        color: '#4da568',
      ),
    ];

/// Routes budget API requests to [budgets] / [categories] and records each
/// request in [log].
MockClient budgetsMockClient({
  List<Map<String, dynamic>>? budgets,
  List<Map<String, dynamic>>? categories,
  List<http.Request>? log,
  int statusCode = 200,
}) =>
    MockClient(budgetsMockHandler(
      budgets: budgets,
      categories: categories,
      log: log,
      statusCode: statusCode,
    ));

/// The request handler behind [budgetsMockClient], for tests that wrap it.
Future<http.Response> Function(http.Request) budgetsMockHandler({
  List<Map<String, dynamic>>? budgets,
  List<Map<String, dynamic>>? categories,
  List<http.Request>? log,
  int statusCode = 200,
}) {
  final budgetList = budgets ?? [budgetJson()];
  final categoryList = categories ?? octoberCategories();

  return (request) async {
    log?.add(request);
    if (statusCode != 200) {
      return http.Response('{"error":"nope"}', statusCode);
    }
    final segments = request.url.pathSegments;
    final resource = segments.length >= 3 ? segments[2] : '';
    final id = segments.length >= 4 ? segments[3] : null;

    if (resource == 'budgets') {
      if (id == null) {
        final stripped = budgetList.map(_withoutDerived).toList();
        return _json({
          'budgets': stripped,
          'pagination': _pagination(stripped.length),
        });
      }
      final match = budgetList.where((b) => b['id'] == id);
      return match.isEmpty
          ? http.Response('{"error":"not_found"}', 404)
          : _json(match.first);
    }

    if (resource == 'budget_categories') {
      if (id == null) {
        final budgetId = request.url.queryParameters['budget_id'];
        final filtered = categoryList
            .where((c) => budgetId == null || c['budget_id'] == budgetId)
            .map(_withoutDerived)
            .toList();
        return _json({
          'budget_categories': filtered,
          'pagination': _pagination(filtered.length),
        });
      }
      final match = categoryList.where((c) => c['id'] == id);
      return match.isEmpty
          ? http.Response('{"error":"not_found"}', 404)
          : _json(match.first);
    }

    return http.Response('{"error":"unexpected"}', 500);
  };
}

const _derivedKeys = {
  'actual_spending',
  'actual_spending_cents',
  'actual_income',
  'actual_income_cents',
  'available_to_spend',
  'available_to_spend_cents',
  'available_to_allocate',
  'available_to_allocate_cents',
  'rolled_over_amount',
  'rolled_over_amount_cents',
};

Map<String, dynamic> _withoutDerived(Map<String, dynamic> json) =>
    Map.of(json)..removeWhere((key, _) => _derivedKeys.contains(key));

Map<String, dynamic> _pagination(int count) => {
      'page': 1,
      'per_page': 100,
      'total_count': count,
      'total_pages': 1,
    };

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

String _usd(int cents) {
  final negative = cents < 0;
  final abs = cents.abs();
  final dollars = abs ~/ 100;
  final rem = (abs % 100).toString().padLeft(2, '0');
  final grouped = dollars.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (_) => ',',
      );
  return '${negative ? '-' : ''}\$$grouped.$rem';
}
