import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/transaction_split.dart';
import 'api_config.dart';
import 'transactions_service.dart';

/// HTTP client for `/api/v1/transactions/:id/split`.
///
/// Addressing a split child resolves to its parent server-side, so any id in
/// the split can be passed as [transactionId].
class TransactionSplitsService {
  final http.Client _client;

  /// Deadline for each request, response body included.
  final Duration _timeout;

  TransactionSplitsService({
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _timeout = timeout;

  Uri _url(String transactionId) => Uri.parse(
        '${ApiConfig.baseUrl}/api/v1/transactions/'
        '${Uri.encodeComponent(transactionId)}/split',
      );

  Map<String, String> _headers(String accessToken) => {
        ...ApiConfig.getAuthHeaders(accessToken),
        'Content-Type': 'application/json',
      };

  /// Returns `{'success': true, 'split': TransactionSplit?}`. The server's
  /// "Transaction is not split" 404 means `split` is null rather than an
  /// error. Any other 404 (the transaction was deleted or is not visible to
  /// this user) is a failure, so it is never cached as a confirmed unsplit.
  Future<Map<String, dynamic>> getSplit({
    required String accessToken,
    required String transactionId,
  }) async {
    try {
      final response = await _client
          .get(_url(transactionId), headers: _headers(accessToken))
          .timeout(_timeout);

      if (response.statusCode == 200) {
        return {
          'success': true,
          'split': TransactionSplit.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>,
          ),
        };
      }
      if (response.statusCode == 404 && _isNotSplitResponse(response.body)) {
        return {'success': true, 'split': null};
      }
      return _failure(response, 'Failed to load split');
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  /// Splits an unsplit transaction (POST).
  Future<Map<String, dynamic>> createSplit({
    required String accessToken,
    required String transactionId,
    required List<SplitRowInput> rows,
  }) {
    return _write(
      method: 'POST',
      accessToken: accessToken,
      transactionId: transactionId,
      rows: rows,
      fallback: 'Failed to split transaction',
    );
  }

  /// Replaces every child of an existing split (PATCH).
  Future<Map<String, dynamic>> updateSplit({
    required String accessToken,
    required String transactionId,
    required List<SplitRowInput> rows,
  }) {
    return _write(
      method: 'PATCH',
      accessToken: accessToken,
      transactionId: transactionId,
      rows: rows,
      fallback: 'Failed to update split',
    );
  }

  /// Removes the split and restores the parent (DELETE).
  Future<Map<String, dynamic>> deleteSplit({
    required String accessToken,
    required String transactionId,
  }) async {
    try {
      final response = await _client
          .delete(_url(transactionId), headers: _headers(accessToken))
          .timeout(_timeout);

      if (response.statusCode == 204 || response.statusCode == 200) {
        return {'success': true};
      }
      return _failure(response, 'Failed to unsplit transaction');
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  Future<Map<String, dynamic>> _write({
    required String method,
    required String accessToken,
    required String transactionId,
    required List<SplitRowInput> rows,
    required String fallback,
  }) async {
    final body = jsonEncode({
      'split': {'splits': rows.map((row) => row.toJson()).toList()},
    });

    try {
      final request = http.Request(method, _url(transactionId))
        ..headers.addAll(_headers(accessToken))
        ..body = body;
      // One deadline for the headers and the body: a stream that stalls after
      // the headers would otherwise leave the save pending forever.
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {
          'success': true,
          'split': TransactionSplit.fromJson(
            jsonDecode(response.body) as Map<String, dynamic>,
          ),
        };
      }
      return _failure(response, fallback);
    } catch (e) {
      return {'success': false, 'error': 'Network error: ${e.toString()}'};
    }
  }

  /// Api::V1::SplitsController#show answers an unsplit transaction with
  /// `{"error": "not_found", "message": "Transaction is not split"}`. A
  /// missing or inaccessible transaction is also a `not_found` 404 (message
  /// "Transaction not found"), so only the message tells the two apart.
  static bool _isNotSplitResponse(String body) {
    try {
      final payload = jsonDecode(body);
      return payload is Map && payload['message'] == 'Transaction is not split';
    } on FormatException {
      return false;
    }
  }

  Map<String, dynamic> _failure(http.Response response, String fallback) {
    if (response.statusCode == 401) {
      return {'success': false, 'error': 'unauthorized'};
    }
    return {
      'success': false,
      'error': TransactionsService.errorMessageFromResponseBody(
        response.body,
        fallback: fallback,
      ),
    };
  }
}
