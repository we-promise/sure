import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/transaction.dart';
import 'api_config.dart';

class TransactionsService {
  static const String mobileIdempotencySource = 'sure_mobile';

  final http.Client _client;

  TransactionsService({http.Client? client})
      : _client = client ?? http.Client();

  Future<Map<String, dynamic>> createTransaction({
    required String accessToken,
    required String accountId,
    required String name,
    required String date,
    required String amount,
    required String currency,
    required String nature,
    String? notes,
    String? categoryId,
    String? merchantId,
    List<String>? tagIds,
    String? externalId,
    String? source,
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions');
    // Idempotency is only valid when both halves of the key are present.
    final hasIdempotencyKey = externalId != null &&
        externalId.isNotEmpty &&
        source != null &&
        source.isNotEmpty;

    final body = {
      'transaction': {
        'account_id': accountId,
        'name': name,
        'date': date,
        'amount': amount,
        'currency': currency,
        'nature': nature,
        if (notes != null) 'notes': notes,
        if (categoryId != null) 'category_id': categoryId,
        if (merchantId != null) 'merchant_id': merchantId,
        if (tagIds != null) 'tag_ids': tagIds,
        if (hasIdempotencyKey) 'external_id': externalId,
        if (hasIdempotencyKey) 'source': source,
      }
    };

    try {
      final response = await _client
          .post(
            url,
            headers: {
              ...ApiConfig.getAuthHeaders(accessToken),
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        return {
          'success': true,
          'transaction': Transaction.fromJson(responseData),
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': errorMessageFromResponseBody(
            response.body,
            fallback: 'Failed to create transaction',
          ),
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<Map<String, dynamic>> getTransactions({
    required String accessToken,
    String? accountId,
    int? page,
    int? perPage,
  }) async {
    final Map<String, String> queryParams = {};

    if (accountId != null) {
      queryParams['account_id'] = accountId;
    }
    if (page != null) {
      queryParams['page'] = page.toString();
    }
    if (perPage != null) {
      queryParams['per_page'] = perPage.toString();
    }

    final baseUri = Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions');
    final url = queryParams.isNotEmpty
        ? baseUri.replace(queryParameters: queryParams)
        : baseUri;

    try {
      final response = await _client.get(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        // Handle both array and object responses
        List<dynamic> transactionsJson;
        Map<String, dynamic>? pagination;

        if (responseData is List) {
          transactionsJson = responseData;
        } else if (responseData is Map &&
            responseData.containsKey('transactions')) {
          transactionsJson = responseData['transactions'];
          // Extract pagination metadata if present
          if (responseData.containsKey('pagination')) {
            pagination = responseData['pagination'];
          }
        } else {
          transactionsJson = [];
        }

        final transactions =
            transactionsJson.map((json) => Transaction.fromJson(json)).toList();

        return {
          'success': true,
          'transactions': transactions,
          if (pagination != null) 'pagination': pagination,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to fetch transactions',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<Map<String, dynamic>> getTransaction({
    required String accessToken,
    required String transactionId,
  }) async {
    final url =
        Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions/$transactionId');

    try {
      final response = await _client.get(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        return {
          'success': true,
          'transaction': Transaction.fromJson(responseData),
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': errorMessageFromResponseBody(
            response.body,
            fallback: 'Failed to fetch transaction',
          ),
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<Map<String, dynamic>> updateTransaction({
    required String accessToken,
    required String transactionId,
    String? name,
    String? date,
    String? amount,
    String? currency,
    String? nature,
    String? notes,
    String? categoryId,
    String? merchantId,
    List<String>? tagIds,
  }) async {
    final url =
        Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions/$transactionId');

    final transaction = <String, dynamic>{
      if (name != null) 'name': name,
      if (date != null) 'date': date,
      if (amount != null) 'amount': amount,
      if (currency != null) 'currency': currency,
      if (nature != null) 'nature': nature,
      if (notes != null) 'notes': notes,
      if (categoryId != null) 'category_id': categoryId,
      if (merchantId != null) 'merchant_id': merchantId,
      if (tagIds != null) 'tag_ids': tagIds,
    };

    if (transaction.isEmpty) {
      return {
        'success': false,
        'error': 'No fields to update',
      };
    }

    try {
      final response = await _client
          .patch(
            url,
            headers: {
              ...ApiConfig.getAuthHeaders(accessToken),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'transaction': transaction}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 204) {
        if (response.body.trim().isEmpty) {
          return {
            'success': true,
            'transaction': null,
          };
        }

        final responseData = jsonDecode(response.body);
        return {
          'success': true,
          'transaction': Transaction.fromJson(responseData),
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        return {
          'success': false,
          'error': errorMessageFromResponseBody(
            response.body,
            fallback: 'Failed to update transaction',
          ),
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<Map<String, dynamic>> deleteTransaction({
    required String accessToken,
    required String transactionId,
  }) async {
    final url =
        Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions/$transactionId');

    try {
      final response = await _client.delete(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 204) {
        return {
          'success': true,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
        };
      } else {
        try {
          final responseData = jsonDecode(response.body);
          return {
            'success': false,
            'error': responseData['error'] ?? 'Failed to delete transaction',
          };
        } catch (e) {
          return {
            'success': false,
            'error': 'Failed to delete transaction: ${response.body}',
          };
        }
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<Map<String, dynamic>> deleteMultipleTransactions({
    required String accessToken,
    required List<String> transactionIds,
  }) async {
    try {
      final results = await Future.wait(
        transactionIds.map((id) => deleteTransaction(
              accessToken: accessToken,
              transactionId: id,
            )),
      );

      final allSuccess = results.every((result) => result['success'] == true);

      if (allSuccess) {
        return {
          'success': true,
          'deleted_count': transactionIds.length,
        };
      } else {
        final failedCount = results.where((r) => r['success'] != true).length;
        return {
          'success': false,
          'error': 'Failed to delete $failedCount transactions',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  static String errorMessageFromResponseBody(
    String body, {
    required String fallback,
  }) {
    try {
      final responseData = jsonDecode(body);
      if (responseData is! Map<String, dynamic>) return fallback;

      final message = responseData['message'] ?? responseData['error'];
      final errors = responseData['errors'];
      final formattedErrors = _formatErrors(errors);

      if (message != null && formattedErrors != null) {
        return '${message.toString()}: $formattedErrors';
      }

      if (formattedErrors != null) return formattedErrors;
      if (message != null) return message.toString();
    } catch (_) {
      return fallback;
    }

    return fallback;
  }

  static String? _formatErrors(dynamic errors) {
    if (errors is List) {
      final parts = errors
          .map((error) => error?.toString().trim() ?? '')
          .where((error) => error.isNotEmpty)
          .toList();
      return parts.isEmpty ? null : parts.join('; ');
    }

    if (errors is Map) {
      final parts = <String>[];
      for (final entry in errors.entries) {
        final field = _humanizeField(entry.key.toString());
        final value = entry.value;
        if (value is List) {
          for (final message in value) {
            final text = message?.toString().trim() ?? '';
            if (text.isNotEmpty) parts.add('$field $text');
          }
        } else {
          final text = value?.toString().trim() ?? '';
          if (text.isNotEmpty) parts.add('$field $text');
        }
      }
      return parts.isEmpty ? null : parts.join('; ');
    }

    return null;
  }

  static String _humanizeField(String field) {
    final words = field
        .replaceAll('_', ' ')
        .split(' ')
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return field;

    final first = words.first;
    words[0] = first[0].toUpperCase() + first.substring(1);
    return words.join(' ');
  }
}
