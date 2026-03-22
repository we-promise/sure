import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import 'api_config.dart';

class AccountsService {
  Future<Map<String, dynamic>> getAccounts({
    required String accessToken,
    int page = 1,
    int perPage = 25,
  }) async {
    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}/api/v1/accounts?page=$page&per_page=$perPage',
      );

      final response = await http.get(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

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
