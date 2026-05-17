import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/models/custom_proxy_header.dart';
import 'package:sure_mobile/services/api_config.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiConfig.clearApiKeyAuth();
    ApiConfig.setBaseUrl(ApiConfig.defaultBaseUrl);
    ApiConfig.setCustomProxyHeaders([]);
  });

  test('adds custom proxy headers to token auth headers', () {
    ApiConfig.setCustomProxyHeaders([
      CustomProxyHeader(name: 'X-Auth-Id', value: 'id'),
      CustomProxyHeader(name: 'X-Auth-Secret', value: 'secret'),
    ]);

    expect(ApiConfig.getAuthHeaders('token'), {
      'X-Auth-Id': 'id',
      'X-Auth-Secret': 'secret',
      'Authorization': 'Bearer token',
      'Accept': 'application/json',
    });
  });

  test('adds custom proxy headers to unauthenticated json headers', () {
    ApiConfig.setCustomProxyHeaders([
      CustomProxyHeader(name: 'X-Mobile-Bypass', value: 'pass'),
    ]);

    expect(ApiConfig.jsonHeaders(), {
      'X-Mobile-Bypass': 'pass',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    });
  });

  test('drops headers with reserved names', () {
    ApiConfig.setCustomProxyHeaders([
      CustomProxyHeader(name: 'Accept', value: 'text/plain'),
      CustomProxyHeader(name: 'Authorization', value: 'should-be-dropped'),
      CustomProxyHeader(name: 'X-Api-Key', value: 'should-be-dropped-too'),
      CustomProxyHeader(name: 'Content-Type', value: 'application/xml'),
      CustomProxyHeader(name: 'X-Auth-Id', value: 'id'),
    ]);

    final result = ApiConfig.customProxyHeaders;
    expect(result.length, 1);
    expect(result.first.name, 'X-Auth-Id');
  });

  test('deduplicates headers by normalized name keeping the last value', () {
    ApiConfig.setCustomProxyHeaders([
      CustomProxyHeader(name: 'X-Auth-Id', value: 'first'),
      CustomProxyHeader(name: 'x-auth-id', value: 'second'),
      CustomProxyHeader(name: 'X-Auth-Id', value: 'third'),
    ]);

    final result = ApiConfig.customProxyHeaders;
    expect(result.length, 1);
    expect(result.first.name, 'X-Auth-Id');
    expect(result.first.value, 'third');
  });

  test('app managed headers win over custom headers', () {
    ApiConfig.setCustomProxyHeaders([
      CustomProxyHeader(name: 'Accept', value: 'text/plain'),
      CustomProxyHeader(name: 'X-Auth-Id', value: 'id'),
    ]);

    expect(ApiConfig.htmlHeaders(), {
      'X-Auth-Id': 'id',
      'Accept': 'text/html',
    });
  });
}
