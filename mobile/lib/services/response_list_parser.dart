import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

List<Map<String, dynamic>> extractJsonObjectList(
  dynamic responseData, {
  String? key,
}) {
  final dynamic rawList;
  if (responseData is List) {
    rawList = responseData;
  } else if (responseData is Map && key != null) {
    rawList = responseData[key] is List ? responseData[key] : const [];
  } else if (responseData is Map) {
    final lists = responseData.values.whereType<List>();
    rawList = lists.isEmpty ? const [] : lists.first;
  } else {
    rawList = const [];
  }

  return (rawList as List)
      .whereType<Map>()
      .map((item) => item.cast<String, dynamic>())
      .toList();
}

Future<Map<String, dynamic>> fetchApiList<T>({
  required String accessToken,
  required String path,
  required String key,
  required String resultKey,
  required T Function(Map<String, dynamic>) fromJson,
  required bool Function(T) isValid,
  required String failureMessage,
}) async {
  final url = Uri.parse('${ApiConfig.baseUrl}$path');

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
      final items = <T>[];
      for (final json in extractJsonObjectList(responseData, key: key)) {
        try {
          final item = fromJson(json);
          if (isValid(item)) {
            items.add(item);
          }
        } on FormatException {
          // Skip malformed metadata records instead of failing the whole list.
        }
      }

      return {'success': true, resultKey: items};
    } else if (response.statusCode == 401) {
      return {'success': false, 'error': 'unauthorized'};
    }

    return {
      'success': false,
      'error': extractErrorMessage(response.body, fallback: failureMessage),
    };
  } catch (e) {
    return {'success': false, 'error': 'Network error: ${e.toString()}'};
  }
}

String extractErrorMessage(String responseBody, {required String fallback}) {
  try {
    final responseData = jsonDecode(responseBody);
    if (responseData is Map) {
      final message = responseData['message'] ?? responseData['error'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString();
      }
    }
  } catch (_) {
    // Fall through to the static caller-provided fallback.
  }

  return fallback;
}
