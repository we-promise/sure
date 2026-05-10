import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/models/custom_proxy_header.dart';

void main() {
  group('CustomProxyHeader', () {
    test('serializes trimmed header name and value', () {
      final header = CustomProxyHeader(name: ' X-Auth-Id ', value: ' abc ');

      expect(header.name, 'X-Auth-Id');
      expect(header.value, 'abc');
      expect(header.toJson(), {
        'name': 'X-Auth-Id',
        'value': 'abc',
      });
      expect(CustomProxyHeader.fromJson(header.toJson()), header);
    });

    test('rejects empty, malformed, and reserved names', () {
      expect(CustomProxyHeader.validateName(''), isNotNull);
      expect(CustomProxyHeader.validateName('Bad Header'), isNotNull);
      expect(CustomProxyHeader.validateName('Bad:Header'), isNotNull);
      expect(CustomProxyHeader.validateName('Authorization'), isNotNull);
      expect(CustomProxyHeader.validateName('X-Api-Key'), isNotNull);
      expect(CustomProxyHeader.validateName('Accept'), isNotNull);
      expect(CustomProxyHeader.validateName('Content-Type'), isNotNull);
    });

    test('allows custom header names with hyphens', () {
      expect(CustomProxyHeader.validateName('X-Auth-Id'), isNull);
      expect(CustomProxyHeader.validateName('X-Auth-Secret'), isNull);
    });

    test('rejects values containing control characters (header injection)', () {
      expect(CustomProxyHeader.validateValue('abc\r\nInjected: 1'), isNotNull);
      expect(CustomProxyHeader.validateValue('abc\tdef'), isNotNull);
      expect(CustomProxyHeader.validateValue('abc\x7Fdef'), isNotNull);
      expect(CustomProxyHeader.validateValue('plain value with spaces'), isNull);
    });

    test('redacts values for display', () {
      expect(
        CustomProxyHeader(name: 'X-Auth-Secret', value: '1234567890').redactedValue,
        '••••••7890',
      );
    });
  });
}
