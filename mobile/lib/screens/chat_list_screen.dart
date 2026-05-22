import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import 'chat_conversation_screen.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  bool _isSelectionMode = false;
  final Set<String> _selectedChatIds = {};

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    await chatProvider.fetchChats(accessToken: accessToken);
  }

  Future<void> _handleRefresh() async {
    await _loadChats();
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      _selectedChatIds.clear();
    });
  }

  void _toggleSelectAll(List<String> allIds) {
    setState(() {
      if (_selectedChatIds.length == allIds.length) {
        _selectedChatIds.clear();
      } else {
        _selectedChatIds
          ..clear()
          ..addAll(allIds);
      }
    });
  }

  void _toggleChatSelection(String id) {
    setState(() {
      if (_selectedChatIds.contains(id)) {
        _selectedChatIds.remove(id);
      } else {
        _selectedChatIds.add(id);
      }
    });
  }

  Future<void> _deleteSelectedChats() async {
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Chats'),
        content: Text(
          'Delete ${_selectedChatIds.length} chat(s)? This cannot be undone.',
        ),
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

    if (confirmed != true || !mounted) return;

    final accessToken = await authProvider.getValidAccessToken();
    if (accessToken == null) {
      await authProvider.logout();
      return;
    }

    final success = await chatProvider.deleteMultipleChats(
      accessToken: accessToken,
      chatIds: _selectedChatIds.toList(),
    );

    if (!mounted) return;

    setState(() {
      _isSelectionMode = false;
      _selectedChatIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Chats deleted' : 'Failed to delete chats',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _openNewChat() async {
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChatConversationScreen(chatId: null),
      ),
    );

    if (mounted) _loadChats();
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}m ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}h ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays}d ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        centerTitle: false,
        actions: [
          if (_isSelectionMode) ...[
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _selectedChatIds.isNotEmpty ? _deleteSelectedChats : null,
            ),
            IconButton(
              icon: const Icon(Icons.select_all),
              onPressed: () {
                final allIds = Provider.of<ChatProvider>(context, listen: false)
                    .chats
                    .map((c) => c.id)
                    .toList();
                _toggleSelectAll(allIds);
              },
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _toggleSelectionMode,
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, right: 12),
              child: InkWell(
                onTap: _handleRefresh,
                child: const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(Icons.refresh),
                ),
              ),
            ),
          ],
        ],
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          if (chatProvider.isLoading && chatProvider.chats.isEmpty) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (chatProvider.errorMessage != null && chatProvider.chats.isEmpty) {
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
                      'Failed to load chats',
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
                      onPressed: _handleRefresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try Again'),
                    ),
                  ],
                ),
              ),
            );
          }

          if (chatProvider.chats.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 64,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No chats yet',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Start a new conversation with the AI assistant.',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _handleRefresh,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: chatProvider.chats.length,
              itemBuilder: (context, index) {
                final chat = chatProvider.chats[index];
                final isSelected = _selectedChatIds.contains(chat.id);
                return Dismissible(
                  key: Key(chat.id),
                  direction: _isSelectionMode
                      ? DismissDirection.none
                      : DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    child: const Icon(
                      Icons.delete,
                      color: Colors.white,
                    ),
                  ),
                  confirmDismiss: (direction) async {
                    return await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Delete Chat'),
                        content: Text('Are you sure you want to delete "${chat.title}"?'),
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
                  },
                  onDismissed: (direction) async {
                    final authProvider = Provider.of<AuthProvider>(context, listen: false);
                    final accessToken = await authProvider.getValidAccessToken();
                    if (accessToken != null) {
                      await chatProvider.deleteChat(
                        accessToken: accessToken,
                        chatId: chat.id,
                      );
                    }
                  },
                  child: ListTile(
                    leading: _isSelectionMode
                        ? Checkbox(
                            value: isSelected,
                            onChanged: (_) => _toggleChatSelection(chat.id),
                          )
                        : CircleAvatar(
                            backgroundColor: colorScheme.primaryContainer,
                            child: Icon(
                              Icons.chat,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                    title: Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: chat.lastMessageAt != null
                        ? Text(_formatDateTime(chat.lastMessageAt!))
                        : null,
                    trailing: chat.messageCount != null && !_isSelectionMode
                        ? Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${chat.messageCount}',
                              style: TextStyle(
                                color: colorScheme.onSecondaryContainer,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : null,
                    onTap: () async {
                      if (_isSelectionMode) {
                        _toggleChatSelection(chat.id);
                        return;
                      }
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChatConversationScreen(chatId: chat.id),
                        ),
                      );
                      _loadChats();
                    },
                    onLongPress: _isSelectionMode
                        ? null
                        : () {
                            setState(() {
                              _isSelectionMode = true;
                              _selectedChatIds.add(chat.id);
                            });
                          },
                  ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openNewChat,
        tooltip: 'New Chat',
        child: const Icon(Icons.add),
      ),
    );
  }
}
