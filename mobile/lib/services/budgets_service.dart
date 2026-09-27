import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/budget.dart';
import 'api_config.dart';

enum BudgetLoadError { unauthorized, forbidden, notFound, unavailable }

class BudgetPage<T> {
  final List<T> items;
  final int page;
  final int totalPages;

  const BudgetPage(this.items, this.page, this.totalPages);
}

/// Read-only access to Sure's budgets. List endpoints intentionally omit
/// derived spending; fetch a show endpoint only when its detail is opened.
class BudgetsService {
  final http.Client _client;
  final bool _ownsClient;

  BudgetsService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<BudgetPage<Budget>> getBudgets({
    required String accessToken,
    int page = 1,
  }) async {
    final json =
        await _get('budgets', accessToken, {'page': '$page', 'per_page': '20'});
    return _page(json, 'budgets', Budget.fromJson);
  }

  Future<Budget> getBudget({
    required String accessToken,
    required String id,
  }) async {
    final json = await _get('budgets/${Uri.encodeComponent(id)}', accessToken);
    return _parse(() => Budget.fromJson(json));
  }

  Future<BudgetPage<BudgetCategory>> getCategories({
    required String accessToken,
    required String budgetId,
    int page = 1,
  }) async {
    final json = await _get('budget_categories', accessToken, {
      'budget_id': budgetId,
      'page': '$page',
      'per_page': '20',
    });
    return _page(json, 'budget_categories', BudgetCategory.fromJson);
  }

  Future<BudgetCategory> getCategory({
    required String accessToken,
    required String id,
  }) async {
    final json =
        await _get('budget_categories/${Uri.encodeComponent(id)}', accessToken);
    return _parse(() => BudgetCategory.fromJson(json));
  }

  T _parse<T>(T Function() parse) {
    try {
      return parse();
    } catch (_) {
      throw BudgetLoadError.unavailable;
    }
  }

  BudgetPage<T> _page<T>(Map<String, dynamic> json, String key,
      T Function(Map<String, dynamic>) parse) {
    return _parse(() {
      final pagination = json['pagination'] as Map<String, dynamic>;
      return BudgetPage(
        (json[key] as List)
            .map((item) => parse(item as Map<String, dynamic>))
            .toList(),
        pagination['page'] as int,
        pagination['total_pages'] as int,
      );
    });
  }

  Future<Map<String, dynamic>> _get(String path, String token,
      [Map<String, String>? query]) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/$path')
          .replace(queryParameters: query);
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(token))
          .timeout(ApiConfig.receiveTimeout);
      switch (response.statusCode) {
        case 200:
          return jsonDecode(response.body) as Map<String, dynamic>;
        case 401:
          throw BudgetLoadError.unauthorized;
        case 403:
          throw BudgetLoadError.forbidden;
        case 404:
          throw BudgetLoadError.notFound;
        default:
          throw BudgetLoadError.unavailable;
      }
    } on BudgetLoadError {
      rethrow;
    } catch (_) {
      // Never surface response bodies, tokens, URLs or financial data in logs.
      throw BudgetLoadError.unavailable;
    }
  }
}
