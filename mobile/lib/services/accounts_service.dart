import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import 'api_config.dart';

class AccountsService {
  AccountsService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The API caps `per_page` at 100.
  static const int maxPerPage = 100;

  /// Upper bound on the pages [getAllAccounts] follows, so a bad `total_pages`
  /// cannot loop forever.
  static const int maxPages = 100;

  /// Fetches every page of accounts the user can access.
  ///
  /// Returns the same shape as [getAccounts], with all pages' accounts in
  /// `accounts` and the last page's `pagination`. If any page fails, that
  /// page's failure is returned and no accounts are, so a caller never
  /// replaces its cache with a partial list.
  Future<Map<String, dynamic>> getAllAccounts({
    required String accessToken,
    int perPage = maxPerPage,
  }) async {
    final accounts = <Account>[];
    Map<String, dynamic>? pagination;
    var page = 1;
    var totalPages = 1;

    while (page <= totalPages && page <= maxPages) {
      final result = await getAccounts(
        accessToken: accessToken,
        page: page,
        perPage: perPage,
      );
      if (result['success'] != true) return result;

      accounts.addAll((result['accounts'] as List<dynamic>).cast<Account>());
      pagination = result['pagination'] as Map<String, dynamic>?;
      totalPages = (pagination?['total_pages'] as num?)?.toInt() ?? 1;
      page++;
    }

    if (totalPages > maxPages) {
      return {
        'success': false,
        'error': 'Too many account pages to load ($totalPages)',
      };
    }

    return {
      'success': true,
      'accounts': accounts,
      'pagination': pagination,
    };
  }

  Future<Map<String, dynamic>> getAccounts({
    required String accessToken,
    int page = 1,
    int perPage = 25,
  }) async {
    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}/api/v1/accounts?page=$page&per_page=$perPage',
      );

      final response = await _client
          .get(
            url,
            headers: ApiConfig.getAuthHeaders(accessToken),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        final accountsList = (responseData['accounts'] as List)
            .map((json) => Account.fromJson(json))
            .toList();

        return {
          'success': true,
          'accounts': accountsList,
          'pagination': responseData['pagination'],
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to fetch accounts',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }
}
