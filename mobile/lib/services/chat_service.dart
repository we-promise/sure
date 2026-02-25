import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/chat.dart';
import '../models/message.dart';
import 'api_config.dart';

class ChatService {
  /// Get list of chats with pagination
  Future<Map<String, dynamic>> getChats({
    required String accessToken,
    int page = 1,
    int perPage = 25,
  }) async {
    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}/api/v1/chats?page=$page&per_page=$perPage',
      );

      final response = await http.get(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);

        final chatsList = (responseData['chats'] as List)
            .map((json) => Chat.fromJson(json))
            .toList();

        return {
          'success': true,
          'chats': chatsList,
          'pagination': responseData['pagination'],
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 403) {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': 'feature_disabled',
          'message': responseData['message'] ?? 'AI features not enabled',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to fetch chats',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Get a specific chat with messages
  Future<Map<String, dynamic>> getChat({
    required String accessToken,
    required String chatId,
    int page = 1,
    int perPage = 50,
  }) async {
    try {
      final url = Uri.parse(
        '${ApiConfig.baseUrl}/api/v1/chats/$chatId?page=$page&per_page=$perPage',
      );

      final response = await http.get(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final chat = Chat.fromJson(responseData);

        return {
          'success': true,
          'chat': chat,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'not_found',
          'message': 'Chat not found',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to fetch chat',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Create a new chat with optional initial message
  Future<Map<String, dynamic>> createChat({
    required String accessToken,
    String? title,
    String? initialMessage,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/chats');

      final body = <String, dynamic>{};

      if (title != null) {
        body['title'] = title;
      }

      if (initialMessage != null) {
        body['message'] = initialMessage;
      }

      final response = await http.post(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        final chat = Chat.fromJson(responseData);

        return {
          'success': true,
          'chat': chat,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 403) {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': 'feature_disabled',
          'message': responseData['message'] ?? 'AI features not enabled',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to create chat',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Send a message to a chat
  Future<Map<String, dynamic>> sendMessage({
    required String accessToken,
    required String chatId,
    required String content,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/chats/$chatId/messages');

      final response = await http.post(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'content': content,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 201) {
        final responseData = jsonDecode(response.body);
        final message = Message.fromJson(responseData);

        return {
          'success': true,
          'message': message,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'not_found',
          'message': 'Chat not found',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to send message',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Update chat title
  Future<Map<String, dynamic>> updateChat({
    required String accessToken,
    required String chatId,
    required String title,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/chats/$chatId');

      final response = await http.patch(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'title': title,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        final chat = Chat.fromJson(responseData);

        return {
          'success': true,
          'chat': chat,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'not_found',
          'message': 'Chat not found',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to update chat',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Delete a chat
  Future<Map<String, dynamic>> deleteChat({
    required String accessToken,
    required String chatId,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/chats/$chatId');

      final response = await http.delete(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 204) {
        return {
          'success': true,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'not_found',
          'message': 'Chat not found',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to delete chat',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  /// Retry the last assistant response in a chat
  Future<Map<String, dynamic>> retryMessage({
    required String accessToken,
    required String chatId,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/chats/$chatId/messages/retry');

      final response = await http.post(
        url,
        headers: ApiConfig.getAuthHeaders(accessToken),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 202) {
        return {
          'success': true,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'unauthorized',
          'message': 'Session expired. Please login again.',
        };
      } else if (response.statusCode == 404) {
        return {
          'success': false,
          'error': 'not_found',
          'message': 'Chat not found',
        };
      } else {
        final responseData = jsonDecode(response.body);
        return {
          'success': false,
          'error': responseData['error'] ?? 'Failed to retry message',
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
