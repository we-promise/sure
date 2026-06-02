import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import '../models/chat.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../models/message.dart';
import '../constants/suggested_questions.dart';
import '../widgets/typing_indicator.dart';

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class ChatConversationScreen extends StatefulWidget {
  /// Null means this is a brand-new chat — it will be created on first send.
  final String? chatId;

  /// When true, shows a hamburger menu that opens a drawer listing all chats.
  final bool showDrawer;

  const ChatConversationScreen({
    super.key,
    required this.chatId,
    this.showDrawer = false,
  });

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Tracks the real chat ID once the chat has been created.
  String? _chatId;

  ChatProvider? _chatProvider;
  bool _listenerAdded = false;
  bool _isSendInFlight = false;

  // Drawer selection state
  bool _drawerSelectionMode = false;
  final Set<String> _selectedChatIds = {};

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
    if (widget.showDrawer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadChats());
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
    if (chatProvider.isWaitingForResponse || chatProvider.isSendingMessage || chatProvider.isPolling) {
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

  Future<void> _sendSuggestedQuestion(String question) async {
    if (!mounted) return;
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    if (chatProvider.isSendingMessage || chatProvider.isWaitingForResponse) return;
    _messageController.text = question;
    await _sendMessage();
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
    if (_isSendInFlight) return;
    final content = _messageController.text.trim();
    if (content.isEmpty) return;
    setState(() => _isSendInFlight = true);

    try {
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
    } finally {
      if (mounted) setState(() => _isSendInFlight = false);
    }
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

  // ── Drawer helpers ──────────────────────────────────────────────────────────

  Future<void> _loadChats() async {
    if (!mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) return;
    await chatProvider.fetchChats(accessToken: accessToken);
  }

  void _startNewChat() {
    _scaffoldKey.currentState?.closeDrawer();
    if (_chatId == null) return;
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    setState(() => _chatId = null);
    chatProvider.clearCurrentChat();
  }

  Future<void> _switchToChat(String chatId) async {
    _scaffoldKey.currentState?.closeDrawer();
    if (chatId == _chatId) return;
    // Clear currentChat immediately so the screen shows loading state and
    // _sendMessage cannot target the previous thread while the fetch is in
    // flight. fetchChat never clears currentChat on its own, so without this
    // the old messages stay visible (and writable) until the response arrives.
    Provider.of<ChatProvider>(context, listen: false).clearCurrentChat();
    setState(() => _chatId = chatId);
    await _loadChat();
  }

  Future<void> _deleteSelectedChats() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Chats'),
        content: Text(
            'Delete ${_selectedChatIds.length} chat(s)? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: TextStyle(
                    color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);
    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) return;
    final deletedCurrent = _selectedChatIds.contains(_chatId);
    await chatProvider.deleteMultipleChats(
      accessToken: accessToken,
      chatIds: _selectedChatIds.toList(),
    );
    if (!mounted) return;
    setState(() {
      _drawerSelectionMode = false;
      _selectedChatIds.clear();
      if (deletedCurrent) _chatId = null;
    });
    if (deletedCurrent) {
      Provider.of<ChatProvider>(context, listen: false).clearCurrentChat();
    }
  }

  String _formatChatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final diff = now.difference(dateTime);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  Widget _buildDrawer(ColorScheme colorScheme) {
    return Drawer(
      width: MediaQuery.of(context).size.width,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header — changes when in selection mode
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: _drawerSelectionMode
                  ? Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Cancel',
                          onPressed: () => setState(() {
                            _drawerSelectionMode = false;
                            _selectedChatIds.clear();
                          }),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${_selectedChatIds.length} selected',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        Consumer<ChatProvider>(
                          builder: (context, chatProvider, _) {
                            final allIds =
                                chatProvider.chats.map((c) => c.id).toList();
                            final allSelected =
                                _selectedChatIds.length == allIds.length &&
                                    allIds.isNotEmpty;
                            return IconButton(
                              icon: Icon(allSelected
                                  ? Icons.deselect
                                  : Icons.select_all),
                              tooltip:
                                  allSelected ? 'Deselect all' : 'Select all',
                              onPressed: () => setState(() {
                                if (allSelected) {
                                  _selectedChatIds.clear();
                                } else {
                                  _selectedChatIds
                                    ..clear()
                                    ..addAll(allIds);
                                }
                              }),
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete selected',
                          onPressed: _selectedChatIds.isNotEmpty
                              ? _deleteSelectedChats
                              : null,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('Chats',
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'New Chat',
                          onPressed: _startNewChat,
                        ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Consumer<ChatProvider>(
                builder: (context, chatProvider, _) {
                  if (chatProvider.isLoading && chatProvider.chats.isEmpty) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (chatProvider.chats.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No chats yet.\nStart a new conversation!',
                          textAlign: TextAlign.center,
                          style:
                              TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: _loadChats,
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 4),
                      itemCount: chatProvider.chats.length,
                      itemBuilder: (context, index) {
                        final chat = chatProvider.chats[index];
                        final isActive =
                            !_drawerSelectionMode && chat.id == _chatId;
                        final isSelected =
                            _selectedChatIds.contains(chat.id);
                        return ListTile(
                          selected: isActive,
                          selectedTileColor: colorScheme.primaryContainer
                              .withValues(alpha: 0.3),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 2),
                          leading: _drawerSelectionMode
                              ? Checkbox(
                                  value: isSelected,
                                  onChanged: (_) => setState(() {
                                    if (isSelected) {
                                      _selectedChatIds.remove(chat.id);
                                    } else {
                                      _selectedChatIds.add(chat.id);
                                    }
                                  }),
                                )
                              : null,
                          title: Text(
                            chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: chat.lastMessageAt != null
                              ? Text(
                                  _formatChatDateTime(chat.lastMessageAt!),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          onTap: _drawerSelectionMode
                              ? () => setState(() {
                                    if (isSelected) {
                                      _selectedChatIds.remove(chat.id);
                                    } else {
                                      _selectedChatIds.add(chat.id);
                                    }
                                  })
                              : () => _switchToChat(chat.id),
                          onLongPress: _drawerSelectionMode
                              ? null
                              : () => setState(() {
                                    _drawerSelectionMode = true;
                                    _selectedChatIds.add(chat.id);
                                  }),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Message helpers ─────────────────────────────────────────────────────────

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      drawer: widget.showDrawer ? _buildDrawer(colorScheme) : null,
      onDrawerChanged: (isOpen) {
        if (!isOpen && _drawerSelectionMode) {
          setState(() {
            _drawerSelectionMode = false;
            _selectedChatIds.clear();
          });
        }
      },
      appBar: AppBar(
        leading: widget.showDrawer
            ? IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Chats',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              )
            : null,
        title: Consumer<ChatProvider>(
          builder: (context, chatProvider, _) {
            final title = chatProvider.currentChat?.title ?? 'New Conversation';
            return GestureDetector(
              onLongPress: _chatId != null ? _editTitle : null,
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        ),
        actions: [
          if (!widget.showDrawer && widget.chatId != null)
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

          final allMessages = chatProvider.currentChat?.messages ?? [];
          // While waiting for the AI response, hide the last (partial/streaming)
          // assistant message so the typing indicator shows instead of partial content.
          // The full response is revealed once polling detects stable content.
          final messages = chatProvider.isWaitingForResponse
              ? allMessages.where((m) {
                  return !(m.isAssistant && m == allMessages.lastOrNull);
                }).toList()
              : allMessages;
          final firstName =
              Provider.of<AuthProvider>(context, listen: true).user?.firstName;

          return Column(
            children: [
              Expanded(
                child: messages.isEmpty &&
                        !chatProvider.isLoading &&
                        !chatProvider.isSendingMessage &&
                        !chatProvider.isWaitingForResponse
                    ? _EmptyState(
                        firstName: firstName,
                        isSending: false,
                        onQuestionTap: _sendSuggestedQuestion,
                      )
                    : ListView.builder(
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
                padding: EdgeInsets.fromLTRB(
                  16,
                  16,
                  16,
                  16 + MediaQuery.paddingOf(context).bottom,
                ),
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
                          if (!_isSendInFlight && !chatProvider.isSendingMessage && !chatProvider.isWaitingForResponse && !chatProvider.isPolling) _sendMessage();
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
                          onPressed: (_isSendInFlight || chatProvider.isSendingMessage || chatProvider.isWaitingForResponse || chatProvider.isPolling)
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

  /// Builds the markdown stylesheet once per render context instead of inline,
  /// avoiding redundant TextStyle allocations per message bubble.
  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(color: color),
      strong: TextStyle(color: color, fontWeight: FontWeight.bold),
      em: TextStyle(color: color, fontStyle: FontStyle.italic),
      listBullet: TextStyle(color: color),
      h1: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.bold),
      h2: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold),
      h3: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
      code: TextStyle(color: color, fontFamily: 'monospace'),
    );
  }

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
                      if (isUser)
                        Text(
                          message.content,
                          style: TextStyle(
                            color: colorScheme.onPrimary,
                          ),
                        )
                      else
                        MarkdownBody(
                          data: message.content,
                          selectable: false,
                          softLineBreak: true,
                          styleSheet: _markdownStyle(context),
                          sizedImageBuilder: (config) {
                            // Block remote images to prevent unsolicited network requests.
                            if (config.uri.scheme == 'http' || config.uri.scheme == 'https') {
                              return const SizedBox.shrink();
                            }
                            return Image.asset(config.uri.toString());
                          },
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

class _EmptyState extends StatelessWidget {
  final String? firstName;
  final bool isSending;
  final void Function(String) onQuestionTap;

  const _EmptyState({
    required this.firstName,
    required this.isSending,
    required this.onQuestionTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final name = (firstName ?? '').trim();
    final greeting = name.isNotEmpty ? 'Hi $name, how can I help?' : 'How can I help?';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 32),
        Text(
          greeting,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        ...suggestedQuestions.map(
          (q) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              onPressed: isSending ? null : () => onQuestionTap(q.text),
              icon: Icon(q.icon, size: 20),
              label: Text(q.text, textAlign: TextAlign.left),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                foregroundColor: colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ],
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
