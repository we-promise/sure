import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/cash_flow.dart';
import 'api_config.dart';
import 'transactions_service.dart';

/// Fetches server-calculated cash flow from `GET /api/v1/cash_flow`.
class CashFlowService {
  CashFlowService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;

  /// Only a client this service created is closed by [close]; an injected
  /// one belongs to the caller.
  final bool _ownsClient;

  /// Releases the HTTP client's pooled connections if this service owns it.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// The family's month start day (1..28) from `GET /api/v1/family_settings`,
  /// which the web's "This month" / "Last month" presets follow.
  ///
  /// Returns `{'success': true, 'month_start_day': int}` or
  /// `{'success': false, 'error': …}` (`'unauthorized'` on 401).
  Future<Map<String, dynamic>> getMonthStartDay({
    required String accessToken,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/family_settings');
    try {
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 401) {
        return {'success': false, 'error': 'unauthorized'};
      }
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final day = data is Map ? data['month_start_day'] : null;
        if (day is int && day >= 1 && day <= 28) {
          return {'success': true, 'month_start_day': day};
        }
      }
      return {'success': false, 'error': 'Failed to load family settings'};
    } catch (_) {
      return {'success': false, 'error': 'Failed to load family settings'};
    }
  }

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
          'error': TransactionsService.errorMessageFromResponseBody(
            response.body,
            fallback: 'Failed to load cash flow',
          ),
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Unable to load cash flow. Please try again later.',
      };
    }
  }
}
