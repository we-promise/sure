import 'package:flutter/foundation.dart';

class LogEntry {
  final DateTime timestamp;
  final String level; // INFO, DEBUG, ERROR, WARNING
  final String tag;
  final String message;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  String get formattedTime {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}.'
        '${timestamp.millisecond.toString().padLeft(3, '0')}';
  }
}

class LogService with ChangeNotifier {
  static final LogService instance = LogService._internal();
  factory LogService() => instance;
  LogService._internal();

  final List<LogEntry> _logs = [];
  final int _maxLogs = 1000; // Keep last 1000 logs

  List<LogEntry> get logs => List.unmodifiable(_logs);

  void log(String tag, String message, {String level = 'INFO'}) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    );

    _logs.add(entry);

    // Keep only the last _maxLogs entries
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    // Also print to console for development
    debugPrint('[$level][$tag] $message');

    notifyListeners();
  }

  void debug(String tag, String message) => log(tag, message, level: 'DEBUG');
  void info(String tag, String message) => log(tag, message, level: 'INFO');
  void warning(String tag, String message) => log(tag, message, level: 'WARNING');
  void error(String tag, String message) => log(tag, message, level: 'ERROR');

  void clear() {
    _logs.clear();
    notifyListeners();
  }

  String exportLogs() {
    final buffer = StringBuffer();
    for (final log in _logs) {
      buffer.writeln('${log.formattedTime} [${log.level}][${log.tag}] ${log.message}');
    }
    return buffer.toString();
  }
}
