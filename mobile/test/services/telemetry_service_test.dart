import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:sure_mobile/services/telemetry_service.dart';

void main() {
  group('TelemetryConfig', () {
    test('defaults invalid sample rates to safe Rails-parity values', () {
      expect(
        TelemetryConfig.sampleRate('not-a-number', defaultValue: 0.25),
        0.25,
      );
      expect(TelemetryConfig.sampleRate('2', defaultValue: 0.25), 1);
      expect(TelemetryConfig.sampleRate('-1', defaultValue: 0.25), 0);
    });
  });

  group('TelemetryService', () {
    test('runs app normally when no Sentry DSN is configured', () async {
      final service = TelemetryService(
        config: const TelemetryConfig(
          dsn: '',
          environment: 'test',
          release: '',
          tracesSampleRate: 0.25,
          profilesSampleRate: 0.25,
        ),
      );
      var appStarted = false;

      await service.initialize(appRunner: () {
        appStarted = true;
      });

      expect(appStarted, isTrue);
      expect(service.isActive, isFalse);
      expect(service.navigatorObservers, isEmpty);
    });

    test('sanitizes telemetry data before breadcrumbs and event extras', () {
      final sanitized = TelemetryService.sanitizeData({
        'page': 2,
        'success': true,
        'transaction_id': 'txn_123',
        'accountId': 'acct_123',
        'amount': '123.45',
        'backend_url': 'https://sure.example.test',
        'message': 'raw response body',
        'page_count': 3,
        'success_message': 'finished',
        'stage': 'sync',
        'hostname': 'localhost',
        'storage_path': 'cache/logs',
        'status': 'completed',
      });

      expect(sanitized, containsPair('page', 2));
      expect(sanitized, containsPair('success', true));
      expect(sanitized, containsPair('page_count', 3));
      expect(sanitized, containsPair('success_message', 'finished'));
      expect(sanitized, containsPair('stage', 'sync'));
      expect(sanitized, containsPair('hostname', 'localhost'));
      expect(sanitized, containsPair('storage_path', 'cache/logs'));
      expect(sanitized, containsPair('status', 'completed'));
      expect(sanitized, isNot(contains('transaction_id')));
      expect(sanitized, isNot(contains('accountId')));
      expect(sanitized, isNot(contains('amount')));
      expect(sanitized, isNot(contains('backend_url')));
      expect(sanitized, isNot(contains('message')));
    });

    test('sanitizes nested telemetry maps without preserving sensitive keys',
        () {
      final sanitized = TelemetryService.sanitizeValue({
        'status': 'ok',
        'pagination': {
          'page': 1,
          'transaction_id': 'txn_123',
          'backend_url': 'https://sure.example.test',
        },
        'items': [
          {'success': true, 'account_id': 'acct_123'},
        ],
      });

      expect(
        sanitized,
        equals({
          'status': 'ok',
          'pagination': {'page': 1},
          'items': [
            {'success': true},
          ],
        }),
      );
    });

    test('caps iterable telemetry values after sanitizing entries', () {
      final sanitized = TelemetryService.sanitizeValue(
        List.generate(
            25, (index) => {'page': index, 'account_id': 'acct_$index'}),
      );

      expect(sanitized, isA<List<Object?>>());
      expect(sanitized as List<Object?>, hasLength(20));
      expect(sanitized.first, equals({'page': 0}));
      expect(sanitized.last, equals({'page': 19}));
    });

    test('traceAsync rethrows callback errors when telemetry is inactive',
        () async {
      final service = TelemetryService(
        config: const TelemetryConfig(
          dsn: '',
          environment: 'test',
          release: '',
          tracesSampleRate: 0.25,
          profilesSampleRate: 0.25,
        ),
      );

      expect(
        service.traceAsync<void>(
          'sync.transactions_fetch',
          'Mobile transaction fetch',
          () => throw StateError('offline failure'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('preserves only safe opaque Sentry user ids', () {
      expect(
        TelemetryService.sanitizeUserId(
          '123e4567-e89b-12d3-a456-426614174000',
        ),
        '123e4567-e89b-12d3-a456-426614174000',
      );
      expect(TelemetryService.sanitizeUserId('user@example.com'), isNull);
      expect(
        TelemetryService.sanitizeUserId('https://sure.example.test/user/1'),
        isNull,
      );
      expect(TelemetryService.sanitizeUserId('Bearer token'), isNull);
    });

    test('filterEvent removes sensitive user fields', () {
      final event = SentryEvent(
        user: SentryUser(
          id: 'user@example.com',
          email: 'user@example.com',
          username: 'full name',
        ),
      );

      final filtered = TelemetryService.filterEvent(event, Hint())!;
      final userJson = filtered.user!.toJson().toString();

      expect(filtered.user, isNotNull);
      expect(filtered.user!.id, 'redacted');
      expect(userJson, isNot(contains('user@example.com')));
      expect(userJson, isNot(contains('full name')));
    });

    test('drops HTTP breadcrumbs instead of preserving URLs or headers', () {
      final crumb = Breadcrumb.http(
        url: Uri.parse('https://sure.example.test/api/transactions'),
        method: 'GET',
      );

      expect(TelemetryService.filterBreadcrumb(crumb, Hint()), isNull);
    });

    test('filters breadcrumbs before they leave the device', () {
      final crumb = Breadcrumb(
        category: 'sync',
        message: 'Fetched email=user@example.com amount=123.45',
        data: {
          'page_count': 2,
          'success_message': 'completed',
          'account_id': 'acct_123',
          'merchantName': 'Corner Store',
        },
      );

      final filtered = TelemetryService.filterBreadcrumb(crumb, Hint())!;

      expect(filtered.message, isNot(contains('user@example.com')));
      expect(filtered.message, isNot(contains('123.45')));
      expect(filtered.data, containsPair('page_count', 2));
      expect(filtered.data, containsPair('success_message', 'completed'));
      expect(filtered.data, isNot(contains('account_id')));
      expect(filtered.data, isNot(contains('merchantName')));
    });

    test('scrubs navigator route ids and drops route arguments', () {
      final settings = TelemetryService.scrubRouteSettings(
        const RouteSettings(
          name: '/accounts/123/transactions',
          arguments: {'account_id': 'acct_123'},
        ),
      )!;

      expect(settings.name, '/accounts/:id/transactions');
      expect(settings.arguments, isNull);
      expect(
        TelemetryService.scrubRouteName('/accounts/acct_12345678/transactions'),
        '/accounts/:id/transactions',
      );
      expect(
        TelemetryService.scrubRouteName('/api/v1/auth/login'),
        '/api/v1/auth/login',
      );
    });

    test('sanitizes event messages, exceptions, request data, and tags', () {
      final event = SentryEvent(
        message: const SentryMessage(
          'Failed for email=user@example.com amount=123.45',
        ),
        exceptions: const [
          SentryException(
            type: 'StateError',
            value: 'backendUrl=https://sure.example.test',
          ),
        ],
        request: SentryRequest(
          url: 'https://sure.example.test/api/transactions',
          method: 'POST',
          data: {'name': 'Coffee'},
          headers: {'Authorization': 'Bearer secret-token'},
        ),
        tags: {
          'operation': 'sync.transactions_fetch',
          'account_id': 'acct_123',
        },
        // ignore: deprecated_member_use
        extra: {
          'page': 1,
          'merchantName': 'Corner Store',
        },
      );

      final filtered = TelemetryService.filterEvent(event, Hint())!;

      expect(filtered.message!.formatted, isNot(contains('user@example.com')));
      expect(filtered.message!.formatted, isNot(contains('123.45')));
      expect(
          filtered.exceptions!.single.value, isNot(contains('sure.example')));
      expect(filtered.request!.url, '/api/transactions');
      expect(filtered.request!.data, isNull);
      expect(filtered.request!.headers, isEmpty);
      expect(
          filtered.tags, containsPair('operation', 'sync.transactions_fetch'));
      expect(filtered.tags, isNot(contains('account_id')));
      // ignore: deprecated_member_use
      expect(filtered.extra, containsPair('page', 1));
      // ignore: deprecated_member_use
      expect(filtered.extra, isNot(contains('merchantName')));
    });

    test('collapses local database exception details before sending', () {
      final event = SentryEvent(
        exceptions: const [
          SentryException(
            type: 'DatabaseException',
            value: 'DatabaseException(no such table: transactions) '
                'sql SELECT * FROM transactions WHERE account_id = acct_123',
          ),
        ],
      );

      final filtered = TelemetryService.filterEvent(event, Hint())!;

      expect(
        filtered.exceptions!.single.value,
        'Local database operation failed',
      );
    });

    test('conversationId is stable, pseudonymous, and survives sanitization',
        () {
      const chatId = 'a3bb189e-8bf9-3888-9912-ace4e6543002';

      final id = TelemetryService.conversationId(chatId);

      // Deterministic per chat, different across chats.
      expect(TelemetryService.conversationId(chatId), id);
      expect(
        TelemetryService.conversationId('b4cc290f-9c0a-4999-aa23-bdf5f7654113'),
        isNot(id),
      );

      // Does not leak the raw chat UUID...
      expect(id, isNot(contains(chatId)));
      // ...and is not itself redacted by the sanitization pipeline the way a
      // UUID would be, so gen_ai.conversation.id stays groupable in Sentry.
      expect(TelemetryService.sanitizeValue(id), id);
    });
  });
}
