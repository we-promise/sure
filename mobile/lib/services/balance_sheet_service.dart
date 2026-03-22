import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';

class BalanceSheetService {
  Future<Map<String, dynamic>> getBalanceSheet({
    required String accessToken,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/balance_sheet');

      final response = await http.get(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        return {
          'success': true,
          'currency': responseData['currency'] as String?,
          'net_worth': responseData['net_worth'],
          'assets': responseData['assets'],
          'liabilities': responseData['liabilities'],
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to fetch balance sheet',
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
