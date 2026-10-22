import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/providers/chat_provider.dart';
import 'package:sure_mobile/services/chat_service.dart';

String _message(int id) => jsonEncode({
      'id': '$id',
      'type': 'UserMessage',
      'role': 'user',
      'content': 'message $id',
      'created_at': '2026-06-01T00:00:0$id' 'Z',
      'updated_at': '2026-06-01T00:00:0$id' 'Z',
    });

http.Response _chatPage({
  required int page,
  required int totalPages,
  required List<int> messageIds,
}) {
  return http.Response(
    jsonEncode({
      'id': 'chat_1',
      'title': 'Test chat',
      'created_at': '2026-06-01T00:00:00Z',
      'updated_at': '2026-06-01T00:00:00Z',
      'messages': messageIds.map((id) => jsonDecode(_message(id))).toList(),
      'pagination': {
        'page': page,
        'per_page': 50,
        'total_count': 4,
        'total_pages': totalPages,
      },
    }),
    200,
  );
}

void main() {
  group('ChatProvider.fetchChat pagination', () {
    test('merges every page so older and newer messages both surface', () async {
      final requestedPages = <String>[];

      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/chats/chat_1');
        final page = request.url.queryParameters['page'] ?? '1';
        requestedPages.add(page);

        switch (page) {
          case '1':
            // Oldest slice — all the app used to render.
            return _chatPage(page: 1, totalPages: 2, messageIds: [1, 2]);
          case '2':
            // Newest slice — previously dropped on mobile.
            return _chatPage(page: 2, totalPages: 2, messageIds: [3, 4]);
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));

      await provider.fetchChat(accessToken: 'token', chatId: 'chat_1');

      final messages = provider.currentChat!.messages;
      expect(requestedPages, ['1', '2']);
      expect(messages.map((m) => m.id).toList(), ['1', '2', '3', '4']);
      expect(provider.hasIncompleteHistory, isFalse);
    });

    test('de-dupes messages that overlap across pages', () async {
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        switch (page) {
          case '1':
            return _chatPage(page: 1, totalPages: 2, messageIds: [1, 2]);
          case '2':
            // id 2 overlaps with page 1 and must not render twice.
            return _chatPage(page: 2, totalPages: 2, messageIds: [2, 3]);
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));

      await provider.fetchChat(accessToken: 'token', chatId: 'chat_1');

      expect(
        provider.currentChat!.messages.map((m) => m.id).toList(),
        ['1', '2', '3'],
      );
    });

    test('keeps partial history when a later page fails', () async {
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        if (page == '1') {
          return _chatPage(page: 1, totalPages: 2, messageIds: [1, 2]);
        }
        return http.Response('{"error":"not_found"}', 404);
      });

      final provider = ChatProvider(chatService: ChatService(client: client));

      await provider.fetchChat(accessToken: 'token', chatId: 'chat_1');

      // Page 2 failed, but the chat is still usable with page 1's messages.
      expect(
        provider.currentChat!.messages.map((m) => m.id).toList(),
        ['1', '2'],
      );
      // ...and the provider flags that the history is incomplete.
      expect(provider.hasIncompleteHistory, isTrue);
    });
  });
}
