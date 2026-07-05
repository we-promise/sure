import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'log_service.dart';

class TelemetryConfig {
  static const _dsn = String.fromEnvironment('SENTRY_DSN');
  static const _environment = String.fromEnvironment(
    'SENTRY_ENVIRONMENT',
    defaultValue: 'mobile',
  );
  static const _release = String.fromEnvironment('SENTRY_RELEASE');
  static const _tracesSampleRate = String.fromEnvironment(
    'SENTRY_TRACES_SAMPLE_RATE',
  );
  static const _profilesSampleRate = String.fromEnvironment(
    'SENTRY_PROFILES_SAMPLE_RATE',
  );

  final String dsn;
  final String environment;
  final String release;
  final double tracesSampleRate;
  final double profilesSampleRate;

  const TelemetryConfig({
    required this.dsn,
    required this.environment,
    required this.release,
    required this.tracesSampleRate,
    required this.profilesSampleRate,
  });

  factory TelemetryConfig.fromEnvironment() {
    return TelemetryConfig(
      dsn: _dsn,
      environment: _environment.trim().isEmpty ? 'mobile' : _environment,
      release: _release,
      tracesSampleRate: sampleRate(_tracesSampleRate, defaultValue: 0.25),
      profilesSampleRate: sampleRate(_profilesSampleRate, defaultValue: 0.25),
    );
  }

  bool get isConfigured => dsn.trim().isNotEmpty;

  static double sampleRate(
    String value, {
    required double defaultValue,
  }) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed.isNaN || parsed.isInfinite) {
      return defaultValue;
    }

    if (parsed < 0) return 0;
    if (parsed > 1) return 1;
    return parsed;
  }
}

class TelemetryService {
  static final TelemetryService instance = TelemetryService();

  /// Agent name reported on AI monitoring spans. Matches the backend's
  /// LlmInstrumentation::AGENT_NAME so both ends of the assistant flow show
  /// up under the same agent in Sentry's AI Agents dashboard.
  static const aiAgentName = 'sure_assistant';

  final TelemetryConfig _config;
  final SentryNavigatorObserver _navigatorObserver = SentryNavigatorObserver(
    enableAutoTransactions: false,
    routeNameExtractor: scrubRouteSettings,
  );
  bool _initialized = false;

  TelemetryService({TelemetryConfig? config})
      : _config = config ?? TelemetryConfig.fromEnvironment();

  bool get isConfigured => _config.isConfigured;
  bool get isActive => isConfigured && _initialized;

  List<NavigatorObserver> get navigatorObservers =>
      isConfigured ? [_navigatorObserver] : const [];

  Future<void> initialize({
    required FutureOr<void> Function() appRunner,
  }) async {
    if (!isConfigured) {
      await appRunner();
      return;
    }

    var appRunnerStarted = false;

    try {
      await SentryFlutter.init(
        (options) {
          options.dsn = _config.dsn.trim();
          options.environment = _config.environment;
          if (_config.release.trim().isNotEmpty) {
            options.release = _config.release.trim();
          }
          options.tracesSampleRate = _config.tracesSampleRate;
          // AI agent turns are sampled as complete span trees — dropping the
          // root loses every gen_ai child span — so keep them at 100% while
          // other transactions use the configured rate.
          options.tracesSampler = (samplingContext) {
            final operation = samplingContext.transactionContext.operation;
            if (operation.startsWith('gen_ai')) return 1.0;
            return _config.tracesSampleRate;
          };
          // TODO: Remove this suppression once sentry_flutter stabilizes
          // options.profilesSampleRate, then revalidate _config.profilesSampleRate
          // against the upstream changelog.
          // ignore: experimental_member_use
          options.profilesSampleRate = _config.profilesSampleRate;
          options.sendDefaultPii = false;
          options.attachScreenshot = false;
          options.maxRequestBodySize = MaxRequestBodySize.never;
          options.maxResponseBodySize = MaxResponseBodySize.never;
          options.beforeSend = filterEvent;
          options.beforeSendTransaction = filterTransaction;
          options.beforeBreadcrumb = filterBreadcrumb;
          _initialized = true;
        },
        appRunner: () async {
          appRunnerStarted = true;
          await appRunner();
        },
      );
    } catch (e, stackTrace) {
      if (appRunnerStarted) rethrow;

      _initialized = false;
      LogService.instance.warning(
        'Telemetry',
        'Sentry initialization failed; continuing without telemetry: '
            '${e.runtimeType}\n${stackTrace.runtimeType}',
      );
      await appRunner();
    }
  }

  Future<void> setUserId(String? userId) async {
    if (!isActive) return;

    await Sentry.configureScope((scope) async {
      final safeUserId = sanitizeUserId(userId);
      await scope
          .setUser(safeUserId == null ? null : SentryUser(id: safeUserId));
    });
  }

  Future<void> clearUser() => setUserId(null);

  void addBreadcrumb(
    String category,
    String message, {
    Map<String, dynamic>? data,
    SentryLevel level = SentryLevel.info,
  }) {
    if (!isActive) return;

    unawaited(Sentry.addBreadcrumb(
      Breadcrumb(
        category: LogService.sanitize(category),
        message: _sanitizeFreeformText(message),
        data: sanitizeData(data),
        level: level,
      ),
    ));
  }

  Future<T> traceAsync<T>(
    String operation,
    String description,
    Future<T> Function() callback, {
    Map<String, dynamic>? data,
    bool Function(T result)? isSuccess,
  }) async {
    if (!isActive) return await callback();

    final span = Sentry.startTransaction(
      _sanitizeFreeformText(description),
      LogService.sanitize(operation),
      bindToScope: false,
    );

    for (final entry in sanitizeData(data).entries) {
      span.setData(entry.key, entry.value);
    }

    try {
      final result = await callback();
      final status = isSuccess == null || isSuccess(result)
          ? const SpanStatus.ok()
          : const SpanStatus.internalError();
      await span.finish(status: status);
      return result;
    } catch (e, stackTrace) {
      span.throwable = e;
      await span.finish(status: const SpanStatus.internalError());
      await captureHandledException(
        e,
        stackTrace,
        operation: operation,
      );
      rethrow;
    }
  }

  Object? startSpan(
    String operation,
    String description, {
    Map<String, dynamic>? data,
  }) {
    if (!isActive) return null;

    final span = Sentry.startTransaction(
      _sanitizeFreeformText(description),
      LogService.sanitize(operation),
      bindToScope: false,
    );

    for (final entry in sanitizeData(data).entries) {
      span.setData(entry.key, entry.value);
    }

    return span;
  }

  Future<void> finishSpan(
    Object? span, {
    required bool success,
    Object? throwable,
  }) async {
    if (span is! ISentrySpan) return;

    if (throwable != null) {
      span.throwable = throwable;
    }

    try {
      await span.finish(
        status:
            success ? const SpanStatus.ok() : const SpanStatus.internalError(),
      );
    } catch (e) {
      _logTelemetryFailure('Span finish', e);
    }
  }

  Future<void> captureHandledException(
    Object exception,
    StackTrace? stackTrace, {
    required String operation,
  }) async {
    if (!isActive) return;

    try {
      await Sentry.captureException(
        exception,
        stackTrace: stackTrace,
        withScope: (scope) async {
          await scope.setTag('operation', LogService.sanitize(operation));
        },
      );
    } catch (e) {
      _logTelemetryFailure('Handled exception capture', e);
    }
  }

  static SentryEvent? filterEvent(SentryEvent event, Hint hint) {
    final eventMessage = event.message;
    final message = eventMessage?.copyWith(
      formatted: _sanitizeFreeformText(eventMessage.formatted),
      template: _sanitizeOptionalString(eventMessage.template),
      params: eventMessage.params?.map(sanitizeValue).toList(),
    );
    final exceptions = event.exceptions
        ?.map((exception) => exception.copyWith(
              value: exception.value == null
                  ? null
                  : _sanitizeFreeformText(exception.value!),
            ))
        .toList();
    final breadcrumbs = event.breadcrumbs
        ?.map((crumb) => filterBreadcrumb(crumb, Hint()))
        .toList()
      ?..removeWhere((crumb) => crumb == null);

    return event.copyWith(
      message: message,
      exceptions: exceptions,
      breadcrumbs: breadcrumbs?.cast<Breadcrumb>(),
      user: _scrubUser(event.user),
      request: event.request == null ? null : _scrubRequest(event.request!),
      // ignore: deprecated_member_use
      extra: _sanitizeEventExtra(event),
      tags: event.tags == null ? null : _sanitizeTags(event.tags!),
    );
  }

  static SentryTransaction? filterTransaction(SentryTransaction transaction) {
    final breadcrumbs = transaction.breadcrumbs
        ?.map((crumb) => filterBreadcrumb(crumb, Hint()))
        .toList()
      ?..removeWhere((crumb) => crumb == null);

    return transaction.copyWith(
      transaction: transaction.transaction == null
          ? null
          : scrubRouteName(transaction.transaction!),
      breadcrumbs: breadcrumbs?.cast<Breadcrumb>(),
      request: transaction.request == null
          ? null
          : _scrubRequest(transaction.request!),
      // ignore: deprecated_member_use
      extra: _sanitizeTransactionExtra(transaction),
      tags: transaction.tags == null ? null : _sanitizeTags(transaction.tags!),
    );
  }

  static Breadcrumb? filterBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
    if (breadcrumb == null) return null;
    if (breadcrumb.type == 'http' || breadcrumb.category == 'http') return null;

    return breadcrumb.copyWith(
      category: breadcrumb.category == null
          ? null
          : LogService.sanitize(breadcrumb.category!),
      message: breadcrumb.message == null
          ? null
          : _sanitizeFreeformText(breadcrumb.message!),
      data: sanitizeData(breadcrumb.data),
    );
  }

  static Map<String, dynamic> sanitizeData(Map<String, dynamic>? data) {
    if (data == null || data.isEmpty) return const {};

    final sanitized = <String, dynamic>{};
    for (final entry in data.entries) {
      final key = LogService.sanitize(entry.key);
      if (_isSensitiveKey(key)) continue;

      final value = sanitizeValue(entry.value);
      if (value != null) {
        sanitized[key] = value;
      }
    }
    return sanitized;
  }

  static Object? sanitizeValue(Object? value) {
    if (value == null || value is bool || value is num) return value;

    if (value is String) {
      final sanitized = LogService.sanitize(value);
      return sanitized.length > 120 ? sanitized.substring(0, 120) : sanitized;
    }

    if (value is Map) {
      final sanitized = <String, dynamic>{};
      for (final entry in value.entries.take(20)) {
        final key = LogService.sanitize(entry.key.toString());
        if (_isSensitiveKey(key)) continue;

        final sanitizedValue = sanitizeValue(entry.value);
        if (sanitizedValue != null) {
          sanitized[key] = sanitizedValue;
        }
      }
      return sanitized;
    }

    if (value is Iterable) {
      return value
          .take(20)
          .map(sanitizeValue)
          .where((item) => item != null)
          .toList();
    }

    return LogService.sanitize(value.runtimeType.toString());
  }

  /// Stable pseudonymous conversation id for AI telemetry
  /// (`gen_ai.conversation.id`). Chat ids are UUIDs, which this service's
  /// privacy layer deliberately redacts — hashing keeps AI spans groupable
  /// per conversation in Sentry without exposing the raw identifier.
  /// Uses simple 31-multiplier hashing so it stays exact on the web build
  /// (all intermediate values fit in a JS double).
  static String conversationId(String chatId) {
    var hash = 7;
    for (final unit in chatId.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return hash.toRadixString(16);
  }

  static String? sanitizeUserId(String? userId) {
    final trimmed = userId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (_looksSensitiveUserId(trimmed)) return null;

    return trimmed.length > 80 ? trimmed.substring(0, 80) : trimmed;
  }

  static String? _sanitizeOptionalString(String? value) {
    return value == null ? null : _sanitizeFreeformText(value);
  }

  static bool _isSensitiveKey(String key) {
    final normalized = _normalizeDataKey(key);
    const sensitiveKeys = {
      'authorization',
      'token',
      'access_token',
      'refresh_token',
      'auth_token',
      'password',
      'secret',
      'api_key',
      'apikey',
      'x_api_key',
      'header',
      'headers',
      'auth_header',
      'custom_proxy_header',
      'custom_proxy_headers',
      'url',
      'uri',
      'host',
      'backend_url',
      'base_url',
      'email',
      'amount',
      'account_id',
      'server_id',
      'transaction_id',
      'merchant_id',
      'category_id',
      'tag_id',
      'tag_ids',
      'user_id',
      'local_id',
      'account_name',
      'merchant_name',
      'category_name',
      'display_name',
      'transaction_name',
      'first_name',
      'last_name',
      'payload',
      'body',
      'chat',
      'message',
      'note',
      'sqlite',
      'database',
      'path',
    };

    return sensitiveKeys.contains(normalized);
  }

  static Map<String, String> _sanitizeTags(Map<String, String> tags) {
    final sanitized = <String, String>{};
    for (final entry in tags.entries) {
      final key = LogService.sanitize(entry.key);
      if (_isSensitiveKey(key)) continue;

      sanitized[key] = LogService.sanitize(entry.value);
    }
    return sanitized;
  }

  static SentryRequest _scrubRequest(SentryRequest request) {
    return SentryRequest(
      method: request.method,
      url: _scrubUrlToPath(request.url),
    );
  }

  static SentryUser? _scrubUser(SentryUser? user) {
    if (user == null) return null;

    final safeUserId = sanitizeUserId(user.id);
    return SentryUser(id: safeUserId ?? 'redacted');
  }

  static Map<String, dynamic>? _sanitizeEventExtra(SentryEvent event) {
    // ignore: deprecated_member_use
    final extra = event.extra;
    return extra == null ? null : sanitizeData(extra);
  }

  static Map<String, dynamic>? _sanitizeTransactionExtra(
    SentryTransaction transaction,
  ) {
    // ignore: deprecated_member_use
    final extra = transaction.extra;
    return extra == null ? null : sanitizeData(extra);
  }

  static bool _looksSensitiveUserId(String userId) {
    return RegExp(
      r'(@|https?://|bearer\s+|authorization|token|secret|password|api[-_]?key)',
      caseSensitive: false,
    ).hasMatch(userId);
  }

  static String _sanitizeFreeformText(String value) {
    final sanitized = LogService.sanitize(value);
    if (_looksLikeDatabaseDetail(sanitized)) {
      return 'Local database operation failed';
    }

    return sanitized.length > 240 ? sanitized.substring(0, 240) : sanitized;
  }

  static bool _looksLikeDatabaseDetail(String value) {
    return RegExp(
      r'\b(sqflite|sqlite|databaseexception|sql\s|select\s|insert\s|update\s|delete\s|pragma\s|from\s+\w+|where\s+\w+|no such table)\b',
      caseSensitive: false,
    ).hasMatch(value);
  }

  static void _logTelemetryFailure(String action, Object error) {
    LogService.instance.warning(
      'Telemetry',
      '$action failed; continuing without interrupting app flow: '
          '${error.runtimeType}',
    );
  }

  static RouteSettings? scrubRouteSettings(RouteSettings? settings) {
    if (settings == null) return null;

    return RouteSettings(
      name: settings.name == null ? null : scrubRouteName(settings.name!),
    );
  }

  static String scrubRouteName(String value) {
    final sanitized = _sanitizeFreeformText(value);
    final parsed = Uri.tryParse(sanitized);
    final rawPath = parsed?.hasAbsolutePath == true ? parsed!.path : sanitized;
    final path = rawPath.split('?').first;

    final scrubbed = path.split('/').map((segment) {
      if (segment.isEmpty) return segment;
      if (_looksLikeRouteIdentifier(segment)) return ':id';

      return segment;
    }).join('/');

    return scrubbed.length > 240 ? scrubbed.substring(0, 240) : scrubbed;
  }

  static String? _scrubUrlToPath(String? value) {
    if (value == null || value.trim().isEmpty) return null;

    final parsed = Uri.tryParse(value);
    final path = parsed == null || parsed.path.isEmpty ? value : parsed.path;
    final scrubbed = scrubRouteName(path);

    return scrubbed.isEmpty ? null : scrubbed;
  }

  static String _normalizeDataKey(String key) {
    return key
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)}_${match.group(2)}',
        )
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  static bool _looksLikeRouteIdentifier(String segment) {
    return RegExp(r'^\d+$').hasMatch(segment) ||
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(segment) ||
        RegExp(r'^[a-z]+_[a-z0-9_-]{8,}$', caseSensitive: false)
            .hasMatch(segment) ||
        RegExp(r'^[0-9a-f]{16,}$', caseSensitive: false).hasMatch(segment);
  }
}
