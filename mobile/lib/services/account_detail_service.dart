import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import '../models/account_balance.dart';
import '../models/account_holding.dart';
import 'api_config.dart';
import 'log_service.dart';

class AccountDetailService {
  final http.Client _client;
  final bool _ownsClient;

  AccountDetailService({http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<Map<String, dynamic>> getAccountDetail({
    required String accessToken,
    required String accountId,
  }) async {
    final accountPathId = Uri.encodeComponent(accountId);
    final url =
        Uri.parse('${ApiConfig.baseUrl}/api/v1/accounts/$accountPathId');

    try {
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return {
          'success': true,
          'account': Account.fromJson(jsonDecode(response.body)),
        };
      }

      return _failureFromStatus(response.statusCode, 'Failed to fetch account');
    } catch (e) {
      _logFailure('getAccountDetail', e);
      return {
        'success': false,
        'error': 'Unable to load account details. Please try again later.',
      };
    }
  }

  Future<Map<String, dynamic>> getBalances({
    required String accessToken,
    required String accountId,
    int perPage = 30,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/balances').replace(
      queryParameters: {
        'account_id': accountId,
        'per_page': perPage.toString(),
      },
    );

    try {
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body) as Map<String, dynamic>;
        final balances = (responseData['balances'] as List<dynamic>? ?? [])
            .map(
              (json) => AccountBalance.fromJson(json as Map<String, dynamic>),
            )
            .toList();

        return {'success': true, 'balances': balances};
      }

      return _failureFromStatus(
        response.statusCode,
        'Failed to fetch balances',
      );
    } catch (e) {
      _logFailure('getBalances', e);
      return {
        'success': false,
        'error': 'Unable to load balance history. Please try again later.',
      };
    }
  }

  Future<Map<String, dynamic>> getHoldings({
    required String accessToken,
    required String accountId,
    int perPage = 5,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/holdings').replace(
      queryParameters: {
        'account_id': accountId,
        'per_page': perPage.toString(),
      },
    );

    try {
      final response = await _client
          .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body) as Map<String, dynamic>;
        final holdings = (responseData['holdings'] as List<dynamic>? ?? [])
            .map(
              (json) => AccountHolding.fromJson(json as Map<String, dynamic>),
            )
            .toList();

        return {'success': true, 'holdings': holdings};
      }

      return _failureFromStatus(
        response.statusCode,
        'Failed to fetch holdings',
      );
    } catch (e) {
      _logFailure('getHoldings', e);
      return {
        'success': false,
        'error': 'Unable to load holdings. Please try again later.',
      };
    }
  }

  Map<String, dynamic> _failureFromStatus(int statusCode, String fallback) {
    if (statusCode == 401) {
      return {'success': false, 'error': 'unauthorized'};
    }

    return {'success': false, 'error': fallback};
  }

  void _logFailure(String operation, Object error) {
    LogService.instance.error(
      'AccountDetailService',
      '$operation failed with ${error.runtimeType}',
    );
  }
}
