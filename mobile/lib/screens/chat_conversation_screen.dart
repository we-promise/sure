import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/chat.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../models/message.dart';
import '../widgets/typing_indicator.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class ChatConversationScreen extends StatefulWidget {
  /// Null means this is a brand-new chat — it will be created on first send.
  final String? chatId;

  const ChatConversationScreen({
    super.key,
    required this.chatId,
  });

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// Tracks the real chat ID once the chat has been created.
  String? _chatId;

  ChatProvider? _chatProvider;
  bool _listenerAdded = false;

  @override
  void initState() {
    super.initState();
    _chatId = widget.chatId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _chatProvider = Provider.of<ChatProvider>(context, listen: false);
      _chatProvider!.addListener(_onChatChanged);
      _listenerAdded = true;
      if (_chatId == null) {
        _chatProvider!.clearCurrentChat();
      }
    });
    if (_chatId != null) {
      _loadChat();
    }
  }

  @override
  void dispose() {
    if (_listenerAdded && _chatProvider != null) {
      _chatProvider!.removeListener(_onChatChanged);
      _chatProvider = null;
      _listenerAdded = false;
    }
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChatChanged() {
    if (!mounted) return;
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    if (chatProvider.isWaitingForResponse || chatProvider.isSendingMessage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToBottom();
      });
    }
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadChat({bool forceRefresh = false}) async {
    if (_chatId == null) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    // Skip fetch if the provider already has this chat loaded (e.g. just created).
    if (!forceRefresh && chatProvider.currentChat?.id == _chatId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
      return;
    }

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    await chatProvider.fetchChat(
      accessToken: accessToken,
      chatId: _chatId!,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _sendMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    _messageController.clear();

    if (_chatId == null) {
      // First message in a new chat — create the chat with it.
      final chat = await chatProvider.createChat(
        accessToken: accessToken,
        title: Chat.generateTitle(content),
        initialMessage: content,
      );
      if (!mounted) return;
      if (chat == null) {
        // Restore the message so the user doesn't lose it.
        _messageController.text = content;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(chatProvider.errorMessage ?? 'Failed to start conversation. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      setState(() => _chatId = chat.id);
    } else {
      final shouldUpdateTitle =
          chatProvider.currentChat?.hasDefaultTitle == true;

      final delivered = await chatProvider.sendMessage(
        accessToken: accessToken,
        chatId: _chatId!,
        content: content,
      );

      if (delivered && shouldUpdateTitle) {
        await chatProvider.updateChatTitle(
          accessToken: accessToken,
          chatId: _chatId!,
          title: Chat.generateTitle(content),
        );
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _editTitle() async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final currentTitle = chatProvider.currentChat?.title ?? '';

    final newTitle = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: currentTitle);
        return AlertDialog(
          title: const Text('Edit Title'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Chat Title',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (newTitle != null &&
        newTitle.isNotEmpty &&
        newTitle != currentTitle &&
        mounted) {
      if (_chatId == null) return;
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();
      if (accessToken != null) {
        await chatProvider.updateChatTitle(
          accessToken: accessToken,
          chatId: _chatId!,
          title: newTitle,
        );
      }
    }
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (context, chatProvider, _) {
            final title = chatProvider.currentChat?.title ?? 'New Conversation';
            return GestureDetector(
              onTap: _chatId != null ? _editTitle : null,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_chatId != null) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, size: 18),
                  ],
                ],
              ),
            );
          },
        ),
        actions: [
          if (widget.chatId != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _loadChat(forceRefresh: true),
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          if (chatProvider.isLoading && chatProvider.currentChat == null) {
            return const Center(child: CircularProgressIndicator());
          }

          if (chatProvider.errorMessage != null &&
              chatProvider.currentChat == null &&
              _chatId != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline,
                        size: 64, color: colorScheme.error),
                    const SizedBox(height: 16),
                    Text('Failed to load chat',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      chatProvider.errorMessage!,
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: _loadChat,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final messages = chatProvider.currentChat?.messages ?? [];

          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length +
                      (chatProvider.isWaitingForResponse ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == messages.length) {
                      return const _TypingIndicatorBubble();
                    }
                    return _MessageBubble(
                      message: messages[index],
                      formatTime: _formatTime,
                    );
                  },
                ),
              ),

              // Message input
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.enter):
                        _SendMessageIntent(),
                  },
                  child: Actions(
                    actions: <Type, Action<Intent>>{
                      _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                        onInvoke: (_) {
                          if (!chatProvider.isSendingMessage) _sendMessage();
                          return null;
                        },
                      ),
                    },
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            decoration: InputDecoration(
                              hintText: 'Type a message...',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                            ),
                            maxLines: null,
                            textCapitalization: TextCapitalization.sentences,
                            autofocus: _chatId == null,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.send),
                          onPressed: chatProvider.isSendingMessage
                              ? null
                              : _sendMessage,
                          color: colorScheme.primary,
                          iconSize: 28,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final String Function(DateTime) formatTime;

  const _MessageBubble({
    required this.message,
    required this.formatTime,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = message.isUser;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser)
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(
                Icons.smart_toy,
                size: 18,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                SelectionArea(
                  child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: isUser
                        ? colorScheme.primary
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message.content,
                        style: TextStyle(
                          color: isUser
                              ? colorScheme.onPrimary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (message.toolCalls != null &&
                          message.toolCalls!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: message.toolCalls!.map((toolCall) {
                              return Chip(
                                label: Text(
                                  toolCall.functionName,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatTime(message.createdAt),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isUser)
            CircleAvatar(
              radius: 16,
              backgroundColor: colorScheme.primary,
              child: Icon(
                Icons.person,
                size: 18,
                color: colorScheme.onPrimary,
              ),
            ),
        ],
      ),
    );
  }
}

class _TypingIndicatorBubble extends StatelessWidget {
  const _TypingIndicatorBubble();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: colorScheme.primaryContainer,
            child: Icon(
              Icons.smart_toy,
              size: 18,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const TypingIndicator(),
          ),
        ],
      ),
    );
  }
}
