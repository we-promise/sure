import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/cash_flow.dart';
import 'api_config.dart';

/// Fetches server-calculated cash flow from `GET /api/v1/cash_flow`.
class CashFlowService {
  CashFlowService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Loads the category cash flow graph for an explicit date range
  /// (`view=sankey&start_date=…&end_date=…`), so every preset period uses the
  /// same server aggregation the web Sankey and spending views use.
  ///
  /// Returns `{'success': true, 'report': CashFlowReport}` or
  /// `{'success': false, 'error': …}` (`'unauthorized'` on 401), matching the
  /// other mobile services.
  Future<Map<String, dynamic>> getCashFlow({
    required String accessToken,
    required CashFlowDateRange range,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/cash_flow').replace(
      queryParameters: {
        'view': 'sankey',
        'start_date': range.startIso,
        'end_date': range.endIso,
      },
    );

    try {
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is! Map) {
          return {'success': false, 'error': 'Unexpected cash flow response'};
        }
        return {
          'success': true,
          'report': CashFlowReport.fromJson(Map<String, dynamic>.from(data)),
        };
      } else if (response.statusCode == 401) {
        return {'success': false, 'error': 'unauthorized'};
      } else {
        return {
          'success': false,
          'error': _errorMessage(response.body) ?? 'Failed to load cash flow',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Unable to load cash flow. Please try again later.',
      };
    }
  }

  static String? _errorMessage(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map && data['message'] is String) {
        return data['message'] as String;
      }
    } catch (_) {
      // Non-JSON error bodies fall back to the generic message.
    }
    return null;
  }
}
