import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/log_service.dart';

void main() {
  setUp(() {
    LogService.instance.clear();
  });

  test('sanitize redacts authentication and identity values', () {
    final sanitized = LogService.sanitize(
      'Authorization: Bearer secret-token '
      'X-Api-Key=mobile-secret '
      'email=user@example.com '
      'accountId=123e4567-e89b-12d3-a456-426614174000 '
      'backendUrl=https://sure.example.test/api',
    );

    expect(sanitized, isNot(contains('secret-token')));
    expect(sanitized, isNot(contains('mobile-secret')));
    expect(sanitized, isNot(contains('user@example.com')));
    expect(sanitized, isNot(contains('123e4567-e89b-12d3-a456-426614174000')));
    expect(sanitized, isNot(contains('sure.example.test')));
    expect(sanitized, contains('[redacted]'));
  });

  test('sanitize redacts host-only socket error backends', () {
    final sanitized = LogService.sanitize(
      "SocketException: Failed host lookup: 'private.internal' "
      '(OS Error: nodename nor servname provided, errno = 8)',
    );

    expect(sanitized, contains('Failed host lookup: [host]'));
    expect(sanitized, isNot(contains('private.internal')));

    final unquoted = LogService.sanitize(
      'SocketException: Failed host lookup: private.internal '
      '(OS Error: lookup failed)',
    );
    expect(unquoted, contains('Failed host lookup: [host]'));
    expect(unquoted, isNot(contains('private.internal')));
  });

  test('sanitize redacts financial and merchant values', () {
    final sanitized = LogService.sanitize(
      'transactionName=Coffee amount=123.45 merchantName="Corner Store" '
      '"transaction_id":"txn_123","local_id":"local_123"',
    );

    expect(sanitized, contains('[redacted]'));
    expect(sanitized, isNot(contains('Coffee')));
    expect(sanitized, isNot(contains('123.45')));
    expect(sanitized, isNot(contains('Corner Store')));
    expect(sanitized, isNot(contains('txn_123')));
    expect(sanitized, isNot(contains('local_123')));
  });

  test('sanitize redacts long numeric ids but preserves shorter counts', () {
    final longNumericId = LogService.sanitize('orderId=12345678901234');
    final shorterCount = LogService.sanitize('count=123456789012');
    final millisecondTimestamp = LogService.sanitize('timestamp=1717605296123');

    expect(longNumericId, contains('orderId=[id]'));
    expect(longNumericId, isNot(contains('12345678901234')));
    expect(shorterCount, contains('123456789012'));
    expect(millisecondTimestamp, contains('timestamp=1717605296123'));
  });

  test('sanitize handles empty and safe messages', () {
    expect(LogService.sanitize(''), '');

    const message = 'Fetched 25 transactions on page 2 with syncStatus=pending '
        'filename=main.dart pageName=transactions hostname=localhost '
        'animationName=fadeIn';
    expect(LogService.sanitize(message), message);
  });

  test('sanitize preserves safe name-adjacent operational fields', () {
    const message =
        'filename=main.dart pageName=transactions stage=boot successMessage=ok';

    expect(LogService.sanitize(message), message);
  });

  test('sanitize redacts repeated sensitive values', () {
    final sanitized = LogService.sanitize(
      'email=one@example.com email=two@example.com '
      'Authorization: Bearer first-token Authorization: Bearer second-token',
    );

    expect(sanitized, isNot(contains('one@example.com')));
    expect(sanitized, isNot(contains('two@example.com')));
    expect(sanitized, isNot(contains('first-token')));
    expect(sanitized, isNot(contains('second-token')));
    expect(
        '[redacted]'.allMatches(sanitized), hasLength(greaterThanOrEqualTo(4)));
  });

  test('auth service style errors redact credentials and backend values', () {
    LogService.instance.error(
      'AuthService',
      'Login SocketException: Failed host lookup: '
          "'private.internal' password=secret otp_code=123456 "
          'Authorization: Bearer token-123 email=user@example.com '
          'https://sure.example.test/login',
    );

    final exported = LogService.instance.exportLogs();
    expect(exported, isNot(contains('private.internal')));
    expect(exported, isNot(contains('secret')));
    expect(exported, isNot(contains('123456')));
    expect(exported, isNot(contains('token-123')));
    expect(exported, isNot(contains('user@example.com')));
    expect(exported, isNot(contains('sure.example.test')));
  });

  test('log storage and export use sanitized messages', () {
    LogService.instance.info(
      'Test',
      'Saved transaction transactionName=Coffee amount=9.99 email=user@example.com',
    );

    expect(LogService.instance.logs, hasLength(1));
    expect(LogService.instance.logs.single.message, isNot(contains('Coffee')));
    expect(LogService.instance.logs.single.message, isNot(contains('9.99')));
    expect(LogService.instance.logs.single.message,
        isNot(contains('user@example.com')));

    final exported = LogService.instance.exportLogs();
    expect(exported, isNot(contains('Coffee')));
    expect(exported, isNot(contains('9.99')));
    expect(exported, isNot(contains('user@example.com')));
  });

  test('all log levels store sanitized messages', () {
    LogService.instance.debug('Test', 'accessToken=debug-secret');
    LogService.instance.warning('Test', 'merchantName=Warning Store');
    LogService.instance.error('Test', 'backendUrl=https://sure.example.test');

    final exported = LogService.instance.exportLogs();
    expect(exported, isNot(contains('debug-secret')));
    expect(exported, isNot(contains('Warning Store')));
    expect(exported, isNot(contains('sure.example.test')));
  });

  test('export redacts long interleaved diagnostic messages', () {
    final safeChunks = List.filled(50, 'sync page ok').join(' ');
    LogService.instance.info(
      'Test',
      '$safeChunks accountId=123e4567-e89b-12d3-a456-426614174000 '
          'amount=123456.78 merchantName="Big Store" $safeChunks',
    );

    final exported = LogService.instance.exportLogs();
    expect(exported, contains('sync page ok'));
    expect(exported, isNot(contains('123e4567-e89b-12d3-a456-426614174000')));
    expect(exported, isNot(contains('123456.78')));
    expect(exported, isNot(contains('Big Store')));
  });

  test('sanitize preserves safe operational diagnostics', () {
    final sanitized = LogService.sanitize(
      'Fetched 25 transactions on page 2 with syncStatus=pending '
      'filename=main.dart pageName=transactions hostname=localhost',
    );

    expect(sanitized, contains('Fetched 25 transactions'));
    expect(sanitized, contains('page 2'));
    expect(sanitized, contains('syncStatus=pending'));
    expect(sanitized, contains('filename=main.dart'));
    expect(sanitized, contains('pageName=transactions'));
    expect(sanitized, contains('hostname=localhost'));
  });
}
