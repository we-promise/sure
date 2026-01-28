import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/log_service.dart';

class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  String _selectedLevel = 'ALL';
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    // Set log viewer as active to enable notifications
    LogService.instance.setLogViewerActive(true);
    // Add a test log to confirm logging is working
    LogService.instance.info('LogViewer', 'Log viewer screen opened');
  }

  @override
  void dispose() {
    // Set log viewer as inactive to disable notifications
    LogService.instance.setLogViewerActive(false);
    _scrollController.dispose();
    super.dispose();
  }

  Color _getLevelColor(String level) {
    switch (level) {
      case 'ERROR':
        return Colors.red;
      case 'WARNING':
        return Colors.orange;
      case 'INFO':
        return Colors.blue;
      case 'DEBUG':
        return Colors.grey;
      default:
        return Colors.black;
    }
  }

  IconData _getLevelIcon(String level) {
    switch (level) {
      case 'ERROR':
        return Icons.error;
      case 'WARNING':
        return Icons.warning;
      case 'INFO':
        return Icons.info;
      case 'DEBUG':
        return Icons.bug_report;
      default:
        return Icons.text_snippet;
    }
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          PopupMenuButton<String>(
            initialValue: _selectedLevel,
            onSelected: (value) {
              setState(() {
                _selectedLevel = value;
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'ALL', child: Text('All Levels')),
              const PopupMenuItem(value: 'ERROR', child: Text('Errors Only')),
              const PopupMenuItem(value: 'WARNING', child: Text('Warnings Only')),
              const PopupMenuItem(value: 'INFO', child: Text('Info Only')),
              const PopupMenuItem(value: 'DEBUG', child: Text('Debug Only')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.filter_list),
                  const SizedBox(width: 4),
                  Text(_selectedLevel),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(_autoScroll ? Icons.lock_open : Icons.lock),
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
              });
            },
            tooltip: _autoScroll ? 'Disable Auto-scroll' : 'Enable Auto-scroll',
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final logs = LogService.instance.exportLogs();
              Clipboard.setData(ClipboardData(text: logs));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logs copied to clipboard'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            tooltip: 'Copy Logs',
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Clear Logs'),
                  content: const Text('Are you sure you want to clear all logs?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () {
                        LogService.instance.clear();
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
            },
            tooltip: 'Clear Logs',
          ),
        ],
      ),
      body: Consumer<LogService>(
        builder: (context, logService, child) {
          final logs = _selectedLevel == 'ALL'
              ? logService.logs
              : logService.logs.where((log) => log.level == _selectedLevel).toList();

          WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

          if (logs.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.text_snippet_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No logs yet',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final log = logs[index];
              final color = _getLevelColor(log.level);

              return Container(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.grey.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    _getLevelIcon(log.level),
                    color: color,
                    size: 20,
                  ),
                  title: Text(
                    '[${log.tag}] ${log.message}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: color,
                    ),
                  ),
                  subtitle: Text(
                    log.formattedTime,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: Colors.grey,
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
