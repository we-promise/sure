import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
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
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.logViewerTitle),
        actions: [
          PopupMenuButton<String>(
            initialValue: _selectedLevel,
            onSelected: (value) {
              setState(() {
                _selectedLevel = value;
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'ALL', child: Text(l.logViewerFilterAll)),
              PopupMenuItem(value: 'ERROR', child: Text(l.logViewerFilterError)),
              PopupMenuItem(value: 'WARNING', child: Text(l.logViewerFilterWarning)),
              PopupMenuItem(value: 'INFO', child: Text(l.logViewerFilterInfo)),
              PopupMenuItem(value: 'DEBUG', child: Text(l.logViewerFilterDebug)),
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
            tooltip: _autoScroll ? l.logViewerAutoScrollDisable : l.logViewerAutoScrollEnable,
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final logs = LogService.instance.exportLogs();
              Clipboard.setData(ClipboardData(text: logs));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l.logViewerLogsCopied),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            tooltip: l.logViewerCopyLogs,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(l.logViewerClearLogs),
                  content: Text(l.logViewerClearConfirm),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(l.commonCancel),
                    ),
                    TextButton(
                      onPressed: () {
                        LogService.instance.clear();
                        Navigator.pop(context);
                      },
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                      child: Text(l.logViewerClear),
                    ),
                  ],
                ),
              );
            },
            tooltip: l.logViewerClearLogs,
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
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.text_snippet_outlined, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(
                    AppLocalizations.of(context).logViewerEmpty,
                    style: const TextStyle(fontSize: 16, color: Colors.grey),
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
