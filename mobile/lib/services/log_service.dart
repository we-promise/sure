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
  final int _maxLogs = 500; // Reduced from 1000 to save memory
  bool _isLogViewerActive = false;

  List<LogEntry> get logs => List.unmodifiable(_logs);

  static final List<RegExp> _authPatterns = [
    RegExp(
      r'\b(authorization|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|auth[-_]?token|bearer|password|otp[-_]?code|linking[-_]?code|secret|custom[-_]?proxy[-_]?headers?)\b\s*[:=]\s*(Bearer\s+[A-Za-z0-9._~+/=-]+|"[^"]*"|[^\s,}]+)',
      caseSensitive: false,
    ),
    RegExp(
      r'"(authorization|x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|auth[-_]?token|password|otp[-_]?code|linking[-_]?code|secret)"\s*:\s*("[^"]*"|[0-9.]+|true|false|null)',
      caseSensitive: false,
    ),
  ];

  static final List<RegExp> _businessDataPatterns = [
    RegExp(
      r'\b(local[-_]?id|account[-_]?id|server[-_]?id|transaction[-_]?id|merchant[-_]?id|category[-_]?id|tag[-_]?ids?|user[-_]?id|backend[-_]?url|base[-_]?url|amount|account[-_]?name|merchant[-_]?name|category[-_]?name|display[-_]?name|transaction[-_]?name|email|first[-_]?name|last[-_]?name)\b\s*[:=]\s*("[^"]*"|[^\s,}]+)',
      caseSensitive: false,
    ),
    RegExp(
      r'"(local[-_]?id|account[-_]?id|server[-_]?id|transaction[-_]?id|merchant[-_]?id|category[-_]?id|tag[-_]?ids?|user[-_]?id|backend[-_]?url|base[-_]?url|amount|account[-_]?name|merchant[-_]?name|category[-_]?name|display[-_]?name|transaction[-_]?name|email|first[-_]?name|last[-_]?name)"\s*:\s*("[^"]*"|[0-9.]+|true|false|null)',
      caseSensitive: false,
    ),
  ];
  static final List<RegExp> _sensitiveKeyPatterns = [
    ..._authPatterns,
    ..._businessDataPatterns,
  ];

  static final RegExp _bearerTokenPattern =
      RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
  static final RegExp _urlPattern = RegExp(r'https?://[^\s,}]+');
  static final RegExp _hostLookupPattern = RegExp(
    r'''(Failed host lookup:\s*)['"]?[^'"\s)]+['"]?''',
    caseSensitive: false,
  );
  static final RegExp _socketAddressPattern = RegExp(
    r'\b(address|host)\s*=\s*([^\s,}]+)',
    caseSensitive: false,
  );
  static final RegExp _emailPattern = RegExp(
      r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
      caseSensitive: false);
  static final RegExp _uuidPattern = RegExp(
    r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
    caseSensitive: false,
  );
  static final RegExp _longNumericIdPattern = RegExp(r'\b\d{14,}\b');

  static String sanitize(String message) {
    var sanitized = message;

    for (final pattern in _sensitiveKeyPatterns) {
      sanitized = sanitized.replaceAllMapped(pattern, (match) {
        final key = match.group(1) ?? 'value';
        return '$key=[redacted]';
      });
    }

    sanitized = sanitized
        .replaceAll(_bearerTokenPattern, 'Bearer [redacted]')
        .replaceAll(_urlPattern, '[url]')
        .replaceAllMapped(
            _hostLookupPattern, (match) => '${match.group(1)}[host]')
        .replaceAllMapped(
            _socketAddressPattern, (match) => '${match.group(1)}=[host]')
        .replaceAll(_emailPattern, '[email]')
        .replaceAll(_uuidPattern, '[id]')
        .replaceAll(_longNumericIdPattern, '[id]');

    return sanitized;
  }

  /// Call this when log viewer screen becomes active
  void setLogViewerActive(bool active) {
    _isLogViewerActive = active;
  }

  void log(String tag, String message, {String level = 'INFO'}) {
    final sanitizedMessage = sanitize(message);
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: sanitizedMessage,
    );

    _logs.add(entry);

    // Keep only the last _maxLogs entries
    if (_logs.length > _maxLogs) {
      _logs.removeAt(0);
    }

    // Also print to console for development
    debugPrint('[$level][$tag] $sanitizedMessage');

    // Only notify listeners if log viewer is active to avoid unnecessary rebuilds
    if (_isLogViewerActive) {
      notifyListeners();
    }
  }

  void debug(String tag, String message) => log(tag, message, level: 'DEBUG');
  void info(String tag, String message) => log(tag, message, level: 'INFO');
  void warning(String tag, String message) =>
      log(tag, message, level: 'WARNING');
  void error(String tag, String message) => log(tag, message, level: 'ERROR');

  void clear() {
    _logs.clear();
    notifyListeners();
  }

  String exportLogs() {
    final buffer = StringBuffer();
    // Log messages are sanitized before storage; export should preserve them.
    for (final log in _logs) {
      buffer.writeln(
          '${log.formattedTime} [${log.level}][${log.tag}] ${log.message}');
    }
    return buffer.toString();
  }
}
