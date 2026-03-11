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
  String? _errorMessage;
  Timer? _pollingTimer;
  int _pollCount = 0;
  int _lastSeenMessageCount = 0;
  String _lastSeenLastMessageContent = '';

  /// Max polling attempts before giving up (2 min at 2-second intervals).
  static const int _maxPollAttempts = 60;

  List<Chat> get chats => _chats;
  Chat? get currentChat => _currentChat;
  bool get isLoading => _isLoading;
  bool get isSendingMessage => _isSendingMessage;
  bool get isAssistantResponding => _pollingTimer != null;
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
      _errorMessage = 'Error: ${e.toString()}';
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
      _errorMessage = 'Error: ${e.toString()}';
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
    final trimmedMessage = initialMessage?.trim() ?? '';
    if (trimmedMessage.isEmpty) {
      _errorMessage = 'Message cannot be empty';
      notifyListeners();
      return null;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await _chatService.createChat(
        accessToken: accessToken,
        title: title,
        initialMessage: trimmedMessage,
      );

      if (result['success'] == true) {
        final chat = result['chat'] as Chat;

        // Optimistically ensure the user's message is visible immediately.
        // The API may return the chat without the initial message in its
        // messages array, so we create a local placeholder if needed.
        final hasUserMessage = chat.messages.any(
          (m) => m.isUser && m.content == trimmedMessage,
        );

        final displayChat = hasUserMessage
            ? chat
            : chat.copyWith(
                messages: [
                  ...chat.messages,
                  Message(
                    id: 'optimistic-${DateTime.now().millisecondsSinceEpoch}',
                    type: 'user_message',
                    role: 'user',
                    content: trimmedMessage,
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                  ),
                ],
              );

        _currentChat = displayChat;
        _chats.insert(0, chat);
        _errorMessage = null;

        // Start polling for AI response if initial message was sent
        if (trimmedMessage.isNotEmpty) {
          _startPolling(accessToken, chat.id);
        }

        _isLoading = false;
        notifyListeners();
        return chat;
      } else {
        _errorMessage = result['error'] ?? 'Failed to create chat';
        _isLoading = false;
        notifyListeners();
        return null;
      }
    } catch (e) {
      _errorMessage = 'Error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return null;
    }
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
    notifyListeners();

    try {
      final result = await _chatService.sendMessage(
        accessToken: accessToken,
        chatId: chatId,
        content: content,
      );

      if (result['success'] == true) {
        final message = result['message'] as Message;

        // Add the message to current chat if it's loaded
        if (_currentChat != null && _currentChat!.id == chatId) {
          _currentChat = _currentChat!.copyWith(
            messages: [..._currentChat!.messages, message],
          );
        }

        _errorMessage = null;

        // Start polling for AI response
        _startPolling(accessToken, chatId);
        return true;
      } else {
        _errorMessage = result['error'] ?? 'Failed to send message';
        return false;
      }
    } catch (e) {
      _errorMessage = 'Error: ${e.toString()}';
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

        // Update current chat title only — don't replace the whole chat
        // because polling may have newer messages that would be lost.
        if (_currentChat != null && _currentChat!.id == chatId) {
          _currentChat = _currentChat!.copyWith(title: updatedChat.title);
        }

        notifyListeners();
      }
    } catch (e) {
      _errorMessage = 'Error: ${e.toString()}';
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
      _errorMessage = 'Error: ${e.toString()}';
      notifyListeners();
      return false;
    }
  }

  /// Start polling for new messages (AI responses)
  void _startPolling(String accessToken, String chatId) {
    _stopPolling();
    _pollCount = 0;
    _lastSeenMessageCount = 0;
    _lastSeenLastMessageContent = '';

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      await _pollForUpdates(accessToken, chatId);
    });
  }

  /// Stop polling
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// Poll for updates.
  /// While polling, the assistant's in-progress response is buffered and NOT
  /// shown to the user.  Only once the response has stabilised (identical
  /// message count and content on two consecutive polls) is `_currentChat`
  /// updated so the full message appears all at once.
  Future<void> _pollForUpdates(String accessToken, String chatId) async {
    _pollCount++;

    // Safety net: stop polling after max attempts to avoid infinite polling
    if (_pollCount > _maxPollAttempts) {
      _stopPolling();
      notifyListeners();
      return;
    }

    try {
      final result = await _chatService.getChat(
        accessToken: accessToken,
        chatId: chatId,
      );

      if (result['success'] == true) {
        final updatedChat = result['chat'] as Chat;

        if (_currentChat == null || _currentChat!.id != chatId) {
          _stopPolling();
          notifyListeners();
          return;
        }

        // The server defaults all messages to status "complete", so we
        // cannot rely on the status field.  Instead, stop polling only
        // when the response has truly stabilised: the message count AND
        // the last message's content are identical to what we saw on the
        // previous poll, and the last message is from the assistant.
        final currentCount = updatedChat.messages.length;
        final lastMessage = updatedChat.messages.lastOrNull;
        final currentContent = lastMessage?.content ?? '';

        final isStable = currentCount == _lastSeenMessageCount &&
            currentContent == _lastSeenLastMessageContent;

        _lastSeenMessageCount = currentCount;
        _lastSeenLastMessageContent = currentContent;

        if (isStable &&
            lastMessage != null &&
            lastMessage.isAssistant) {
          // Response is complete — reveal the full message and stop polling
          _currentChat = updatedChat;
          _stopPolling();
          notifyListeners();
        }
        // While still generating, don't update _currentChat so the UI
        // keeps showing the thinking indicator without partial text.
      }
    } catch (e) {
      debugPrint('Polling error: ${e.toString()}');
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
