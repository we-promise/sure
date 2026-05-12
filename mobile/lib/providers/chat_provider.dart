import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../services/chat_service.dart';

class ChatProvider with ChangeNotifier {
  final ChatService _chatService = ChatService();

  List<Chat> _chats = [];
  Chat? _currentChat;
  bool _isLoading = false;
  bool _isSendingMessage = false;
  bool _isWaitingForResponse = false;
  String? _errorMessage;
  Timer? _pollingTimer;
  DateTime? _pollingStartTime;
  bool _isPollingRequestInFlight = false;

  static const _pollingTimeout = Duration(seconds: 20);

  /// Content length of the last assistant message from the previous poll.
  /// Used to detect when the LLM has finished writing (no growth between polls).
  int? _lastAssistantContentLength;

  /// Number of consecutive polls with no content growth.
  /// Requires 2 consecutive stable polls before declaring the response complete,
  /// to avoid prematurely stopping on a brief server-side generation pause.
  int _stablePollingCount = 0;

  List<Chat> get chats => _chats;
  Chat? get currentChat => _currentChat;
  bool get isLoading => _isLoading;
  bool get isSendingMessage => _isSendingMessage;
  bool get isWaitingForResponse => _isWaitingForResponse;
  bool get isPolling => _pollingTimer != null;
  String? get errorMessage => _errorMessage;

  /// Fetch list of chats
  Future<void> fetchChats({
    required String accessToken,
    int page = 1,
    int perPage = 25,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _chatService.getChats(
        accessToken: accessToken,
        page: page,
        perPage: perPage,
      );

      if (result['success'] == true) {
        _chats = result['chats'] as List<Chat>;
        _errorMessage = null;
      } else {
        _errorMessage = result['error'] ?? 'Failed to fetch chats';
      }
    } catch (e) {
      debugPrint('fetchChats error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Fetch a specific chat with messages
  Future<void> fetchChat({
    required String accessToken,
    required String chatId,
  }) async {
    // Stop any in-progress polling — the server response is the source of truth
    // when explicitly fetching a chat. This prevents a stale poll from
    // overwriting the freshly fetched data and ensures the message filter lifts.
    _stopPolling();
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _chatService.getChat(
        accessToken: accessToken,
        chatId: chatId,
      );

      if (result['success'] == true) {
        _currentChat = result['chat'] as Chat;
        _errorMessage = null;
      } else {
        _errorMessage = result['error'] ?? 'Failed to fetch chat';
      }
    } catch (e) {
      debugPrint('fetchChat error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Create a new chat
  Future<Chat?> createChat({
    required String accessToken,
    String? title,
    String? initialMessage,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _chatService.createChat(
        accessToken: accessToken,
        title: title,
        initialMessage: initialMessage,
      );

      if (result['success'] == true) {
        final chat = result['chat'] as Chat;
        _errorMessage = null;

        if (initialMessage != null) {
          // Inject the user message locally so the UI renders it immediately
          // without waiting for the first poll.
          final now = DateTime.now();
          final userMessage = Message(
            id: 'pending_${now.millisecondsSinceEpoch}',
            type: 'text',
            role: 'user',
            content: initialMessage,
            createdAt: now,
            updatedAt: now,
          );
          _currentChat = chat.copyWith(messages: [userMessage]);
          _chats.insert(0, _currentChat!);
          _startPolling(accessToken, chat.id);
        } else {
          _currentChat = chat;
          _chats.insert(0, chat);
        }

        _isLoading = false;
        notifyListeners();
        return _currentChat!;
      } else {
        _errorMessage = result['error'] ?? 'Failed to create chat';
        _isLoading = false;
        notifyListeners();
        return null;
      }
    } catch (e) {
      debugPrint('createChat error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  void _rollbackOptimisticMessage(String optimisticId, String chatId) {
    if (_currentChat != null && _currentChat!.id == chatId) {
      _currentChat = _currentChat!.copyWith(
        messages: _currentChat!.messages
            .where((m) => m.id != optimisticId)
            .toList(),
      );
    }
    _isWaitingForResponse = false;
  }

  /// Send a message to the current chat.
  /// Returns true if delivery succeeded, false otherwise.
  Future<bool> sendMessage({
    required String accessToken,
    required String chatId,
    required String content,
  }) async {
    _isSendingMessage = true;
    _errorMessage = null;

    // Optimistically add the user message so it appears immediately — before
    // the network round-trip completes. This makes the empty-state disappear
    // and the typing indicator show at the same instant.
    final now = DateTime.now();
    final optimisticId = 'pending-${now.millisecondsSinceEpoch}';
    final optimisticMessage = Message(
      id: optimisticId,
      type: 'text',
      role: 'user',
      content: content,
      createdAt: now,
      updatedAt: now,
    );
    if (_currentChat != null && _currentChat!.id == chatId) {
      _currentChat = _currentChat!.copyWith(
        messages: [..._currentChat!.messages, optimisticMessage],
      );
    }
    _isWaitingForResponse = true;
    notifyListeners();

    try {
      final result = await _chatService.sendMessage(
        accessToken: accessToken,
        chatId: chatId,
        content: content,
      );

      if (result['success'] == true) {
        final message = result['message'] as Message;

        // Replace the optimistic message with the confirmed one from the server.
        if (_currentChat != null && _currentChat!.id == chatId) {
          final updated = _currentChat!.messages
              .where((m) => m.id != optimisticMessage.id)
              .toList()
            ..add(message);
          _currentChat = _currentChat!.copyWith(messages: updated);
        }

        _errorMessage = null;

        // Start polling for AI response
        _startPolling(accessToken, chatId);
        return true;
      } else {
        // Roll back the optimistic message on failure.
        _rollbackOptimisticMessage(optimisticId, chatId);
        _errorMessage = result['error'] ?? 'Failed to send message';
        return false;
      }
    } catch (e) {
      // Roll back the optimistic message on error.
      _rollbackOptimisticMessage(optimisticId, chatId);
      debugPrint('sendMessage error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _isSendingMessage = false;
      notifyListeners();
    }
  }

  /// Update chat title
  Future<void> updateChatTitle({
    required String accessToken,
    required String chatId,
    required String title,
  }) async {
    try {
      final result = await _chatService.updateChat(
        accessToken: accessToken,
        chatId: chatId,
        title: title,
      );

      if (result['success'] == true) {
        final updatedChat = result['chat'] as Chat;

        // Update in the list
        final index = _chats.indexWhere((c) => c.id == chatId);
        if (index != -1) {
          _chats[index] = updatedChat;
        }

        // Update current chat if it's the same.
        // Preserve existing messages — the title-update response may omit them.
        if (_currentChat != null && _currentChat!.id == chatId) {
          final Chat newChat;
          if (updatedChat.messages.isEmpty) {
            newChat = updatedChat.copyWith(messages: _currentChat!.messages);
          } else {
            newChat = updatedChat;
          }
          _currentChat = newChat;
        }

        notifyListeners();
      }
    } catch (e) {
      debugPrint('updateChatTitle error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
      notifyListeners();
    }
  }

  /// Delete a chat
  Future<bool> deleteChat({
    required String accessToken,
    required String chatId,
  }) async {
    try {
      final result = await _chatService.deleteChat(
        accessToken: accessToken,
        chatId: chatId,
      );

      if (result['success'] == true) {
        _chats.removeWhere((c) => c.id == chatId);

        if (_currentChat != null && _currentChat!.id == chatId) {
          _currentChat = null;
        }

        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] ?? 'Failed to delete chat';
        notifyListeners();
        return false;
      }
    } catch (e) {
      debugPrint('deleteChat error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
      notifyListeners();
      return false;
    }
  }

  /// Delete multiple chats
  Future<bool> deleteMultipleChats({
    required String accessToken,
    required List<String> chatIds,
  }) async {
    try {
      final result = await _chatService.deleteMultipleChats(
        accessToken: accessToken,
        chatIds: chatIds,
      );

      final deletedCount = (result['deletedCount'] as int?) ?? 0;
      if (result['success'] == true || deletedCount > 0) {
        final failedIds = ((result['failedIds'] as List?) ?? []).cast<String>().toSet();
        final deleted = chatIds.toSet().difference(failedIds);
        _chats.removeWhere((c) => deleted.contains(c.id));

        if (_currentChat != null && deleted.contains(_currentChat!.id)) {
          _currentChat = null;
        }

        notifyListeners();
        return true;
      }

      _errorMessage = 'Failed to delete chats';
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('deleteMultipleChats error: $e');
      _errorMessage = 'Something went wrong. Please try again.';
      notifyListeners();
      return false;
    }
  }

  /// Start polling for new messages (AI responses)
  void _startPolling(String accessToken, String chatId) {
    _pollingTimer?.cancel();
    _lastAssistantContentLength = null;
    _stablePollingCount = 0;
    _isWaitingForResponse = true;
    _pollingStartTime = DateTime.now();
    notifyListeners();

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isPollingRequestInFlight) return;
      _isPollingRequestInFlight = true;
      try {
        await _pollForUpdates(accessToken, chatId);
      } finally {
        _isPollingRequestInFlight = false;
      }
    });
  }

  /// Stop polling
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _pollingStartTime = null;
    _isPollingRequestInFlight = false;
    _isWaitingForResponse = false;
    _lastAssistantContentLength = null;
    _stablePollingCount = 0;
  }

  /// Poll for updates
  Future<void> _pollForUpdates(String accessToken, String chatId) async {
    try {
      final result = await _chatService.getChat(
        accessToken: accessToken,
        chatId: chatId,
      );

      if (result['success'] == true) {
        final updatedChat = result['chat'] as Chat;

        if (_currentChat == null || _currentChat!.id != chatId) return;

        final oldMessages = _currentChat!.messages;
        final newMessages = updatedChat.messages;
        final oldMessageCount = oldMessages.length;
        final newMessageCount = newMessages.length;

        final oldContentLengthById = <String, int>{};
        for (final m in oldMessages) {
          if (m.isAssistant) oldContentLengthById[m.id] = m.content.length;
        }

        bool shouldUpdate = false;

        // New messages added
        if (newMessageCount > oldMessageCount) {
          shouldUpdate = true;
          _lastAssistantContentLength = null;
        } else if (newMessageCount == oldMessageCount) {
          // Same count: check if any assistant message has more content
          for (final m in newMessages) {
            if (m.isAssistant) {
              final oldLen = oldContentLengthById[m.id] ?? 0;
              if (m.content.length > oldLen) {
                shouldUpdate = true;
                break;
              }
            }
          }
        }

        if (shouldUpdate) {
          _currentChat = updatedChat;
          notifyListeners();
        }

        if (updatedChat.error != null && updatedChat.error!.isNotEmpty) {
          if (!shouldUpdate) {
            _currentChat = updatedChat;
          }
          _stopPolling();
          _errorMessage = updatedChat.error;
          notifyListeners();
          return;
        }

        final lastMessage = updatedChat.messages.lastOrNull;
        if (lastMessage != null && lastMessage.isAssistant) {
          final newLen = lastMessage.content.length;
          final previousLen = _lastAssistantContentLength;

          if (newLen > (previousLen ?? -1)) {
            _lastAssistantContentLength = newLen;
            _stablePollingCount = 0;
            if (newLen > 0) {
              // Content is growing — reset the inactivity clock.
              _pollingStartTime = DateTime.now();
              return; // progress made, don't evaluate timeout this tick
            }
            // newLen == 0: empty placeholder, keep polling
          } else if (newLen > 0) {
            // Content stable and non-empty.
            // Require 2 consecutive stable polls before declaring done, to avoid
            // stopping prematurely on a brief server-side generation pause.
            _stablePollingCount++;
            if (_stablePollingCount >= 2) {
              _stopPolling();
              _lastAssistantContentLength = null;
              notifyListeners();
              return;
            }
          }
          // newLen == 0 with previousLen already 0: still empty, keep polling
        }
      }
    } catch (e) {
      // Network error — allow polling to continue; timeout check below will
      // stop it if the deadline has passed.
      debugPrint('Polling error: ${e.toString()}');
    }

    // Evaluate timeout only after the attempt, and only when no progress was made.
    if (_pollingStartTime != null &&
        DateTime.now().difference(_pollingStartTime!) >= _pollingTimeout) {
      _stopPolling();
      _errorMessage = 'The assistant took too long to respond. Please try again.';
      notifyListeners();
    }
  }

  /// Clear current chat
  void clearCurrentChat() {
    _currentChat = null;
    _stopPolling();
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
