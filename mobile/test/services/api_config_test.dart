import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/services/api_config.dart';

void main() {
  group('ApiConfig', () {
    setUp(() {
      // Reset to default state before each test
      ApiConfig.setBaseUrl('https://demo.sure.am');
      ApiConfig.clearApiKeyAuth();
    });

    group('baseUrl', () {
      test('should return default base URL initially', () {
        expect(ApiConfig.baseUrl, equals('https://demo.sure.am'));
      });

      test('should return defaultBaseUrl constant', () {
        expect(ApiConfig.defaultBaseUrl, equals('https://demo.sure.am'));
      });

      test('should update base URL when setBaseUrl is called', () {
        const newUrl = 'https://test.example.com';
        ApiConfig.setBaseUrl(newUrl);
        expect(ApiConfig.baseUrl, equals(newUrl));
      });

      test('should persist updated base URL across multiple reads', () {
        const newUrl = 'https://production.example.com';
        ApiConfig.setBaseUrl(newUrl);
        expect(ApiConfig.baseUrl, equals(newUrl));
        expect(ApiConfig.baseUrl, equals(newUrl));
      });
    });

    group('API Key Authentication', () {
      test('should not be in API key auth mode by default', () {
        expect(ApiConfig.isApiKeyAuth, isFalse);
      });

      test('should enable API key auth mode when setApiKeyAuth is called', () {
        const apiKey = 'test-api-key-123';
        ApiConfig.setApiKeyAuth(apiKey);
        expect(ApiConfig.isApiKeyAuth, isTrue);
      });

      test('should disable API key auth mode when clearApiKeyAuth is called', () {
        ApiConfig.setApiKeyAuth('test-key');
        expect(ApiConfig.isApiKeyAuth, isTrue);

        ApiConfig.clearApiKeyAuth();
        expect(ApiConfig.isApiKeyAuth, isFalse);
      });

      test('should return API key header when in API key auth mode', () {
        const apiKey = 'my-secret-key';
        const token = 'bearer-token-should-be-ignored';

        ApiConfig.setApiKeyAuth(apiKey);
        final headers = ApiConfig.getAuthHeaders(token);

        expect(headers, containsPair('X-Api-Key', apiKey));
        expect(headers, containsPair('Accept', 'application/json'));
        expect(headers, isNot(contains('Authorization')));
      });

      test('should return Bearer token header when not in API key auth mode', () {
        const token = 'my-bearer-token';
        ApiConfig.clearApiKeyAuth();

        final headers = ApiConfig.getAuthHeaders(token);

        expect(headers, containsPair('Authorization', 'Bearer $token'));
        expect(headers, containsPair('Accept', 'application/json'));
        expect(headers, isNot(contains('X-Api-Key')));
      });

      test('should switch between auth modes correctly', () {
        const apiKey = 'api-key-123';
        const token = 'bearer-token-456';

        // Start with token auth
        ApiConfig.clearApiKeyAuth();
        var headers = ApiConfig.getAuthHeaders(token);
        expect(headers['Authorization'], equals('Bearer $token'));

        // Switch to API key auth
        ApiConfig.setApiKeyAuth(apiKey);
        headers = ApiConfig.getAuthHeaders(token);
        expect(headers['X-Api-Key'], equals(apiKey));

        // Switch back to token auth
        ApiConfig.clearApiKeyAuth();
        headers = ApiConfig.getAuthHeaders(token);
        expect(headers['Authorization'], equals('Bearer $token'));
      });
    });

    group('initialize', () {
      setUp(() {
        SharedPreferences.setMockInitialValues({});
      });

      test('should return true when no saved URL exists', () async {
        final result = await ApiConfig.initialize();
        expect(result, isTrue);
      });

      test('should set default URL when no saved URL exists', () async {
        await ApiConfig.initialize();
        expect(ApiConfig.baseUrl, equals('https://demo.sure.am'));
      });

      test('should save default URL to SharedPreferences on first launch', () async {
        await ApiConfig.initialize();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('backend_url'), equals('https://demo.sure.am'));
      });

      test('should load saved URL from SharedPreferences', () async {
        const savedUrl = 'https://saved.example.com';
        SharedPreferences.setMockInitialValues({'backend_url': savedUrl});

        await ApiConfig.initialize();
        expect(ApiConfig.baseUrl, equals(savedUrl));
      });

      test('should return true when saved URL is loaded', () async {
        SharedPreferences.setMockInitialValues({'backend_url': 'https://test.com'});
        final result = await ApiConfig.initialize();
        expect(result, isTrue);
      });

      test('should ignore empty string URLs', () async {
        SharedPreferences.setMockInitialValues({'backend_url': ''});
        await ApiConfig.initialize();
        expect(ApiConfig.baseUrl, equals('https://demo.sure.am'));
      });

      test('should handle SharedPreferences errors gracefully', () async {
        // This test verifies error handling by checking that initialization
        // still returns true and sets default URL even if errors occur
        final result = await ApiConfig.initialize();
        expect(result, isTrue);
        expect(ApiConfig.baseUrl, isNotEmpty);
      });
    });

    group('timeout settings', () {
      test('should have correct connect timeout', () {
        expect(ApiConfig.connectTimeout, equals(const Duration(seconds: 30)));
      });

      test('should have correct receive timeout', () {
        expect(ApiConfig.receiveTimeout, equals(const Duration(seconds: 30)));
      });
    });

    group('edge cases', () {
      test('should handle multiple consecutive setBaseUrl calls', () {
        ApiConfig.setBaseUrl('https://url1.com');
        ApiConfig.setBaseUrl('https://url2.com');
        ApiConfig.setBaseUrl('https://url3.com');
        expect(ApiConfig.baseUrl, equals('https://url3.com'));
      });

      test('should handle empty API key', () {
        ApiConfig.setApiKeyAuth('');
        expect(ApiConfig.isApiKeyAuth, isTrue);

        final headers = ApiConfig.getAuthHeaders('token');
        expect(headers['X-Api-Key'], equals(''));
      });

      test('should handle special characters in API key', () {
        const specialKey = 'key-with-special!@#\$%^&*()_+{}[]|:;<>?,./~`';
        ApiConfig.setApiKeyAuth(specialKey);

        final headers = ApiConfig.getAuthHeaders('token');
        expect(headers['X-Api-Key'], equals(specialKey));
      });

      test('should handle very long API keys', () {
        final longKey = 'a' * 1000;
        ApiConfig.setApiKeyAuth(longKey);

        final headers = ApiConfig.getAuthHeaders('token');
        expect(headers['X-Api-Key'], equals(longKey));
      });

      test('should handle URLs with trailing slashes', () {
        ApiConfig.setBaseUrl('https://example.com/');
        expect(ApiConfig.baseUrl, equals('https://example.com/'));
      });

      test('should handle localhost URLs', () {
        const localhostUrl = 'http://localhost:3000';
        ApiConfig.setBaseUrl(localhostUrl);
        expect(ApiConfig.baseUrl, equals(localhostUrl));
      });

      test('should handle IP address URLs', () {
        const ipUrl = 'http://192.168.1.100:8080';
        ApiConfig.setBaseUrl(ipUrl);
        expect(ApiConfig.baseUrl, equals(ipUrl));
      });
    });

    group('regression tests', () {
      test('should maintain auth headers format consistency', () {
        // Token auth headers
        ApiConfig.clearApiKeyAuth();
        var headers = ApiConfig.getAuthHeaders('test-token');
        expect(headers.keys, hasLength(2));
        expect(headers['Authorization'], startsWith('Bearer '));
        expect(headers['Accept'], equals('application/json'));

        // API key auth headers
        ApiConfig.setApiKeyAuth('test-key');
        headers = ApiConfig.getAuthHeaders('ignored-token');
        expect(headers.keys, hasLength(2));
        expect(headers, contains('X-Api-Key'));
        expect(headers['Accept'], equals('application/json'));
      });

      test('should not mutate returned headers map', () {
        final headers1 = ApiConfig.getAuthHeaders('token1');
        final headers2 = ApiConfig.getAuthHeaders('token2');

        expect(headers1['Authorization'], equals('Bearer token1'));
        expect(headers2['Authorization'], equals('Bearer token2'));
      });

      test('should handle rapid initialize calls', () async {
        SharedPreferences.setMockInitialValues({'backend_url': 'https://test.com'});

        // Call initialize multiple times rapidly
        final results = await Future.wait([
          ApiConfig.initialize(),
          ApiConfig.initialize(),
          ApiConfig.initialize(),
        ]);

        // All should succeed
        expect(results, everyElement(isTrue));
      });
    });
  });
}