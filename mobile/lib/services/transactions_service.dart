import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/transaction.dart';
import 'api_config.dart';

class TransactionsService {
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
  }) async {
    final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions');

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
      }
    };

    try {
      final response = await http
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
        try {
          final responseData = jsonDecode(response.body);
          return {
            'success': false,
            'error': responseData['error'] ?? 'Failed to create transaction',
          };
        } catch (e) {
          return {
            'success': false,
            'error': 'Failed to create transaction: ${response.body}',
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
      final response = await http.get(
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
      final response = await http
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
        try {
          final responseData = jsonDecode(response.body);
          return {
            'success': false,
            'error': responseData['message'] ??
                responseData['error'] ??
                'Failed to update transaction',
          };
        } catch (e) {
          return {
            'success': false,
            'error': 'Failed to update transaction',
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

  Future<Map<String, dynamic>> deleteTransaction({
    required String accessToken,
    required String transactionId,
  }) async {
    final url =
        Uri.parse('${ApiConfig.baseUrl}/api/v1/transactions/$transactionId');

    try {
      final response = await http.delete(
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
}
