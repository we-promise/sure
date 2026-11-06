import 'dart:async';
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

http.Response _chatListPage({
  required int page,
  required int totalPages,
  required List<int> chatIds,
}) {
  return http.Response(
    jsonEncode({
      'chats': chatIds
          .map((id) => {
                'id': 'chat_$id',
                'title': 'Chat $id',
                'created_at': '2026-06-01T00:00:00Z',
                'updated_at': '2026-06-01T00:00:00Z',
              })
          .toList(),
      'pagination': {
        'page': page,
        'per_page': 20,
        'total_count': 5,
        'total_pages': totalPages,
      },
    }),
    200,
  );
}

void main() {
  group('ChatProvider.fetchChats pagination', () {
    test('loads every page of the chat list', () async {
      final requestedPages = <String>[];
      final client = MockClient((request) async {
        expect(request.url.path, '/api/v1/chats');
        final page = request.url.queryParameters['page'] ?? '1';
        requestedPages.add(page);
        switch (page) {
          case '1':
            return _chatListPage(page: 1, totalPages: 3, chatIds: [1, 2]);
          case '2':
            return _chatListPage(page: 2, totalPages: 3, chatIds: [2, 3, 4]);
          case '3':
            return _chatListPage(page: 3, totalPages: 3, chatIds: [5]);
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      await provider.fetchChats(accessToken: 'token');

      expect(requestedPages, ['1', '2', '3']);
      expect(provider.chats.map((c) => c.id).toList(),
          ['chat_1', 'chat_2', 'chat_3', 'chat_4', 'chat_5']);
      expect(provider.errorMessage, isNull);
    });

    test('keeps the pages already loaded when a later page fails', () async {
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        if (page == '1') {
          return _chatListPage(page: 1, totalPages: 2, chatIds: [1, 2]);
        }
        return http.Response('{"error":"not_found"}', 404);
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      await provider.fetchChats(accessToken: 'token');

      expect(provider.chats.map((c) => c.id).toList(), ['chat_1', 'chat_2']);
    });

    test('keeps the list already shown when a later page fails on refresh',
        () async {
      var failPageTwo = false;
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        switch (page) {
          case '1':
            return _chatListPage(page: 1, totalPages: 2, chatIds: [1, 2]);
          case '2':
            if (failPageTwo) return http.Response('{"error":"boom"}', 500);
            return _chatListPage(page: 2, totalPages: 2, chatIds: [3]);
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      await provider.fetchChats(accessToken: 'token');
      expect(provider.chats.map((c) => c.id).toList(),
          ['chat_1', 'chat_2', 'chat_3']);

      failPageTwo = true;
      await provider.fetchChats(accessToken: 'token');

      expect(provider.chats.map((c) => c.id).toList(),
          ['chat_1', 'chat_2', 'chat_3']);
    });

    test('continues after the requested page instead of restarting at page 2',
        () async {
      final requestedPages = <String>[];
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        requestedPages.add(page);
        switch (page) {
          case '3':
            return _chatListPage(page: 3, totalPages: 4, chatIds: [5]);
          case '4':
            return _chatListPage(page: 4, totalPages: 4, chatIds: [6]);
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      await provider.fetchChats(accessToken: 'token', page: 3);

      expect(requestedPages, ['3', '4']);
      expect(provider.chats.map((c) => c.id).toList(), ['chat_5', 'chat_6']);
    });

    test('does not restore a chat deleted while later pages were loading',
        () async {
      final pageTwo = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.method == 'DELETE') return http.Response('', 204);
        final page = request.url.queryParameters['page'] ?? '1';
        switch (page) {
          case '1':
            return _chatListPage(page: 1, totalPages: 2, chatIds: [1, 2]);
          case '2':
            return pageTwo.future;
          default:
            return http.Response('{"error":"unexpected page"}', 500);
        }
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      final fetch = provider.fetchChats(accessToken: 'token');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      await provider.deleteChat(accessToken: 'token', chatId: 'chat_2');
      pageTwo.complete(
          _chatListPage(page: 2, totalPages: 2, chatIds: [3]));
      await fetch;

      expect(provider.chats.map((c) => c.id).toList(), ['chat_1', 'chat_3']);
    });

    test('overlapping refreshes both finish without error', () async {
      final pageTwo = <Completer<http.Response>>[];
      final client = MockClient((request) async {
        final page = request.url.queryParameters['page'] ?? '1';
        if (page == '1') {
          return _chatListPage(page: 1, totalPages: 2, chatIds: [1]);
        }
        final c = Completer<http.Response>();
        pageTwo.add(c);
        return c.future;
      });

      final provider = ChatProvider(chatService: ChatService(client: client));
      final first = provider.fetchChats(accessToken: 'token');
      final second = provider.fetchChats(accessToken: 'token');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(pageTwo.length, 2);

      pageTwo[0].complete(_chatListPage(page: 2, totalPages: 2, chatIds: [2]));
      await first;
      pageTwo[1].complete(_chatListPage(page: 2, totalPages: 2, chatIds: [2]));
      await second;

      expect(provider.errorMessage, isNull);
      expect(provider.chats.map((c) => c.id).toList(), ['chat_1', 'chat_2']);
    });
  });

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
