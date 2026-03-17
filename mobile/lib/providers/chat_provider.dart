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

  /// Content length of the last assistant message from the previous poll.
  /// Used to detect when the LLM has finished writing (no growth between polls).
  int? _lastAssistantContentLength;

  List<Chat> get chats => _chats;
  Chat? get currentChat => _currentChat;
  bool get isLoading => _isLoading;
  bool get isSendingMessage => _isSendingMessage;
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
        _currentChat = chat;
        _chats.insert(0, chat);
        _errorMessage = null;

        // Start polling for AI response if initial message was sent
        if (initialMessage != null) {
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

        // Update current chat if it's the same
        if (_currentChat != null && _currentChat!.id == chatId) {
          _currentChat = updatedChat;
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
    _lastAssistantContentLength = null;

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      await _pollForUpdates(accessToken, chatId);
    });
  }

  /// Stop polling
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
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

        final lastMessage = updatedChat.messages.lastOrNull;
        if (lastMessage != null && lastMessage.isAssistant) {
          final newLen = lastMessage.content.length;
          if (newLen > (_lastAssistantContentLength ?? 0)) {
            _lastAssistantContentLength = newLen;
          } else {
            // Content stable: no growth since last poll
            _stopPolling();
            _lastAssistantContentLength = null;
          }
        }
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
