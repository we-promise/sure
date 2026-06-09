import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/account.dart';
import '../models/account_balance.dart';
import '../models/account_holding.dart';
import '../utils/json_parsing.dart';
import 'api_config.dart';
import 'log_service.dart';

class AccountDetailService {
  static const int _holdingsPageSize = 100;

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
    final displayLimit = perPage.clamp(1, _holdingsPageSize).toInt();

    try {
      final firstPage = await _getHoldingsPage(
        accessToken: accessToken,
        accountId: accountId,
        page: 1,
      );

      if (!firstPage.success) {
        return _failureFromStatus(
          firstPage.statusCode,
          'Failed to fetch holdings',
        );
      }

      final currentHoldings = <AccountHolding>[];
      DateTime? currentDate;
      final totalPages = firstPage.totalPages < 1 ? 1 : firstPage.totalPages;

      // Holdings are chronological, so the latest positions are at the end of
      // the final page. Walk backward only until the date changes; this keeps
      // the common case to page 1 + latest page while still handling accounts
      // whose current positions span a page boundary.
      for (var page = totalPages; page >= 1; page -= 1) {
        final holdingsPage = page == 1
            ? firstPage
            : await _getHoldingsPage(
                accessToken: accessToken,
                accountId: accountId,
                page: page,
              );

        if (!holdingsPage.success) {
          return _failureFromStatus(
            holdingsPage.statusCode,
            'Failed to fetch holdings',
          );
        }

        for (final holding in holdingsPage.holdings.reversed) {
          currentDate ??= holding.date;
          if (!_sameDate(holding.date, currentDate)) {
            return {
              'success': true,
              'holdings': _topHoldings(currentHoldings, displayLimit),
            };
          }
          currentHoldings.add(holding);
        }
      }

      return {
        'success': true,
        'holdings': _topHoldings(currentHoldings, displayLimit),
      };
    } catch (e) {
      _logFailure('getHoldings', e);
      return {
        'success': false,
        'error': 'Unable to load holdings. Please try again later.',
      };
    }
  }

  Future<_HoldingsPage> _getHoldingsPage({
    required String accessToken,
    required String accountId,
    required int page,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/holdings').replace(
      queryParameters: {
        'account_id': accountId,
        'page': page.toString(),
        'per_page': _holdingsPageSize.toString(),
      },
    );

    final response = await _client
        .get(url, headers: ApiConfig.getAuthHeaders(accessToken))
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      return _HoldingsPage.failure(response.statusCode);
    }

    final responseData = jsonDecode(response.body) as Map<String, dynamic>;
    final holdings = (responseData['holdings'] as List<dynamic>? ?? [])
        .map(
          (json) => AccountHolding.fromJson(json as Map<String, dynamic>),
        )
        .toList();
    final pagination = responseData['pagination'] as Map<String, dynamic>?;
    final totalPages = JsonParsing.parseInt(pagination?['total_pages']) ?? 1;

    return _HoldingsPage.success(
      holdings: holdings,
      totalPages: totalPages,
    );
  }

  List<AccountHolding> _topHoldings(
    List<AccountHolding> holdings,
    int displayLimit,
  ) {
    final sorted = holdings.toList()
      ..sort(
        (left, right) =>
            _amountValue(right.amount).compareTo(_amountValue(left.amount)),
      );
    return sorted.take(displayLimit).toList();
  }

  double _amountValue(String amount) {
    final numeric = amount.replaceAll(RegExp(r'[^\d.-]'), '');
    return double.tryParse(numeric) ?? 0;
  }

  bool _sameDate(DateTime left, DateTime right) {
    return left.year == right.year &&
        left.month == right.month &&
        left.day == right.day;
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

class _HoldingsPage {
  final bool success;
  final int statusCode;
  final List<AccountHolding> holdings;
  final int totalPages;

  _HoldingsPage.success({
    required this.holdings,
    required this.totalPages,
  })  : success = true,
        statusCode = 200;

  _HoldingsPage.failure(this.statusCode)
      : success = false,
        holdings = const [],
        totalPages = 1;
}
