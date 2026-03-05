import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_svg/flutter_svg.dart';
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
  final String? chatId;

  const ChatConversationScreen({
    super.key,
    this.chatId,
  });

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  static const List<({IconData icon, String text})> _suggestedQuestions = [
    (
      icon: Icons.help_outline,
      text: 'What is a Chancen ISA?',
    ),
    (
      icon: Icons.show_chart,
      text: 'How does Chancen ISA impact my future income?',
    ),
    (
      icon: Icons.attach_money,
      text: 'Can I repay my Chancen ISA all at once?',
    ),
    (
      icon: Icons.account_balance_wallet_outlined,
      text: 'How to budget in volatile situations?',
    ),
  ];

  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _hasEverHadMessages = false;
  List<Message> _lastNonEmptyMessages = const [];
  String? _activeChatId;
  bool _isInitializingChat = false;

  @override
  void initState() {
    super.initState();
    _activeChatId = widget.chatId;
    _isInitializingChat = _activeChatId != null;

    // Opening a draft chat should never render a previously viewed conversation.
    if (_activeChatId == null) {
      Provider.of<ChatProvider>(context, listen: false).clearCurrentChat();
    }

    _loadChat();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadChat() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    if (_activeChatId == null) {
      chatProvider.clearCurrentChat();
      if (mounted) {
        setState(() {
          _isInitializingChat = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isInitializingChat = true;
      });
    }

    chatProvider.clearCurrentChat();

    await chatProvider.fetchChat(
      accessToken: accessToken,
      chatId: _activeChatId!,
    );

    if (mounted) {
      setState(() {
        _isInitializingChat = false;
      });
    }

    // Scroll to bottom after loading
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
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
    if (mounted && !_hasEverHadMessages) {
      setState(() {
        _hasEverHadMessages = true;
      });
    }

    if (_activeChatId == null) {
      final chat = await chatProvider.createChat(
        accessToken: accessToken,
        title: Chat.generateTitle(content),
        initialMessage: content,
      );

      if (chat == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(chatProvider.errorMessage ?? 'Failed to create chat'),
            backgroundColor: Colors.red,
          ),
        );
      } else if (chat != null && mounted) {
        setState(() {
          _activeChatId = chat.id;
        });
      }

      return;
    }

    final shouldUpdateTitle = chatProvider.currentChat?.hasDefaultTitle == true;

    final delivered = await chatProvider.sendMessage(
      accessToken: accessToken,
      chatId: _activeChatId!,
      content: content,
    );

    if (delivered && shouldUpdateTitle) {
      await chatProvider.updateChatTitle(
        accessToken: accessToken,
        chatId: _activeChatId!,
        title: Chat.generateTitle(content),
      );
    }

    // Scroll to bottom after sending
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

  Future<void> _sendSuggestedQuestion(String question) async {
    if (!mounted) return;

    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    if (chatProvider.isSendingMessage) return;

    _messageController.text = question;
    _messageController.selection = TextSelection.collapsed(
      offset: _messageController.text.length,
    );
    await _sendMessage();
  }

  Future<void> _editTitle() async {
    if (_activeChatId == null) return;

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
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();
      if (accessToken != null) {
        await chatProvider.updateChatTitle(
          accessToken: accessToken,
          chatId: _activeChatId!,
          title: newTitle,
        );
      }
    }
  }

  Future<void> _deleteChat() async {
    if (_activeChatId == null) return;

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chat'),
        content: const Text('Are you sure you want to delete this chat?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldDelete != true || !mounted) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    final deleted = await chatProvider.deleteChat(
      accessToken: accessToken,
      chatId: _activeChatId!,
    );

    if (deleted && mounted) {
      Navigator.pop(context);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(chatProvider.errorMessage ?? 'Failed to delete chat'),
          backgroundColor: Colors.red,
        ),
      );
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
    final authProvider = Provider.of<AuthProvider>(context);
    final firstName = authProvider.user?.firstName ?? 'there';

    return Scaffold(
      appBar: AppBar(
        title: Consumer<ChatProvider>(
          builder: (context, chatProvider, _) {
            final isLoadingExistingChat = _activeChatId != null &&
                (_isInitializingChat ||
                    chatProvider.currentChat == null ||
                    chatProvider.currentChat!.id != _activeChatId);

            return GestureDetector(
              onTap: _activeChatId == null ? null : _editTitle,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      isLoadingExistingChat
                          ? 'Chat'
                          : (chatProvider.currentChat?.title ?? 'New Chat'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_activeChatId != null) ...[
                    const SizedBox(width: 4),
                    const Icon(Icons.edit, size: 18),
                  ],
                ],
              ),
            );
          },
        ),
        actions: [
          if (_activeChatId != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteChat,
              tooltip: 'Delete chat',
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadChat,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          final isLoadingExistingChat = _activeChatId != null &&
              (_isInitializingChat ||
                  chatProvider.currentChat == null ||
                  chatProvider.currentChat!.id != _activeChatId);

          if (isLoadingExistingChat) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (chatProvider.isLoading && chatProvider.currentChat == null) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (chatProvider.errorMessage != null &&
              chatProvider.currentChat == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 64,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load chat',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
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
          if (messages.isNotEmpty) {
            if (!_hasEverHadMessages) {
              _hasEverHadMessages = true;
            }
            _lastNonEmptyMessages = messages;
          }
          final visibleMessages =
              messages.isEmpty && _lastNonEmptyMessages.isNotEmpty
                  ? _lastNonEmptyMessages
                  : messages;

          // Auto-scroll to bottom when messages update or typing indicator appears
          if (visibleMessages.isNotEmpty || chatProvider.isAssistantResponding) {
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

          return Column(
            children: [
              // Messages list
              Expanded(
                child: visibleMessages.isEmpty
                    ? (!_hasEverHadMessages
                        ? ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor:
                                        colorScheme.primaryContainer,
                                    child: SvgPicture.asset(
                                      'assets/images/logomark-color.svg',
                                      width: 18,
                                      height: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Hey $firstName! I am your financial companion, ready to help you learn and grow your money skills.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          'I can explain your Chancen ISA, help you understand budgeting, and teach you about finances. Just ask!',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          "Here's a few questions you can ask:",
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium,
                                        ),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: _suggestedQuestions
                                              .map(
                                                (question) =>
                                                    OutlinedButton.icon(
                                                  onPressed: chatProvider
                                                          .isSendingMessage
                                                      ? null
                                                      : () =>
                                                          _sendSuggestedQuestion(
                                                              question.text),
                                                  icon: Icon(
                                                    question.icon,
                                                    size: 16,
                                                  ),
                                                  label: Text(question.text),
                                                  style:
                                                      OutlinedButton.styleFrom(
                                                    side: BorderSide(
                                                      color: colorScheme
                                                          .outlineVariant,
                                                    ),
                                                    shape:
                                                        const StadiumBorder(),
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                      horizontal: 12,
                                                      vertical: 10,
                                                    ),
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          )
                        : Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Loading conversation…',
                                  style: TextStyle(
                                      color: colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ))
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: visibleMessages.length +
                            (chatProvider.isAssistantResponding ? 1 : 0),
                        itemBuilder: (context, index) {
                          // Show typing indicator as the last item
                          if (chatProvider.isAssistantResponding &&
                              index == visibleMessages.length) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: colorScheme.primaryContainer,
                                    child: SvgPicture.asset(
                                      'assets/images/logomark-color.svg',
                                      width: 18,
                                      height: 18,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16, vertical: 12),
                                      decoration: BoxDecoration(
                                        color: colorScheme.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: const TypingIndicator(),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          final message = visibleMessages[index];
                          return _MessageBubble(
                            message: message,
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
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
                                textCapitalization:
                                    TextCapitalization.sentences,
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
                        const SizedBox(height: 6),
                        Text(
                          'AI can make mistakes. I am here to educate and help you learn. Always double-check important information.',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                    fontSize: 11,
                                  ),
                          textAlign: TextAlign.center,
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
              child: SvgPicture.asset(
                'assets/images/logomark-color.svg',
                width: 18,
                height: 18,
              ),
            ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
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
                      MarkdownBody(
                        data: message.content,
                        selectable: false,
                        softLineBreak: true,
                        styleSheet:
                            MarkdownStyleSheet.fromTheme(Theme.of(context))
                                .copyWith(
                          p: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                          ),
                          strong: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.bold,
                          ),
                          em: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                          listBullet: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                          ),
                          h1: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          h2: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          h3: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          code: TextStyle(
                            color: isUser
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
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
