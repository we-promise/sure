import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:sure_mobile/services/auth_service.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    ApiConfig.setBaseUrl(ApiConfig.defaultBaseUrl);
  });

  test('login handles string errors payloads without throwing', () async {
    final result = await _loginWithResponse({
      'errors': 'Invalid login payload',
    });

    expect(result['success'], false);
    expect(result['error'], 'Invalid login payload');
  });

  test('login flattens mapped error responses', () async {
    final result = await _loginWithResponse({
      'errors': {
        'email': ['is invalid'],
        'base': 'try again',
      },
    });

    expect(result['success'], false);
    expect(result['error'], 'is invalid, try again');
  });

  test('login does not persist tokens when user parsing fails', () async {
    final authService = AuthService();

    final result = await _loginWithResponse(
      {
        'access_token': 'access-token',
        'refresh_token': 'refresh-token',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'created_at': 0,
        'user': {
          'id': 'user_1',
        },
      },
      statusCode: 200,
      authService: authService,
    );

    expect(result['success'], false);
    expect(result['error'], 'Invalid response from server');
    expect(await authService.getStoredTokens(), isNull);
    expect(await authService.getStoredUser(), isNull);
  });

  test('fetchSsoProviders parses configured providers', () async {
    final providers = await _withServer(
      '/api/v1/auth/sso_providers',
      200,
      {
        'providers': [
          {
            'name': 'openid_connect',
            'strategy': 'openid_connect',
            'label': 'Authentik',
          },
          {
            'name': 'google_oauth2',
            'strategy': 'google_oauth2',
            'label': 'Google Oauth2',
          },
        ],
      },
      () => AuthService().fetchSsoProviders(),
    );

    expect(providers!.map((p) => p.name), ['openid_connect', 'google_oauth2']);
    expect(providers.first.label, 'Authentik');
    expect(providers.first.isGoogle, false);
    expect(providers.last.isGoogle, true);
  });

  test('fetchSsoProviders returns null for a malformed response', () async {
    final providers = await _withServer(
      '/api/v1/auth/sso_providers',
      200,
      {'unexpected': true},
      () => AuthService().fetchSsoProviders(),
    );

    expect(providers, isNull);
  });

  test('fetchSsoProviders returns null when the endpoint is missing', () async {
    final providers = await _withServer(
      '/some/other/path',
      200,
      {},
      () => AuthService().fetchSsoProviders(),
    );

    expect(providers, isNull);
  });
}

Future<T> _withServer<T>(
  String path,
  int statusCode,
  Map<String, dynamic> responseBody,
  Future<T> Function() body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    final matched = request.uri.path == path;
    request.response
      ..statusCode = matched ? statusCode : 404
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(matched ? responseBody : {'error': 'Not found'}));
    await request.response.close();
  });

  try {
    ApiConfig.setBaseUrl('http://${server.address.host}:${server.port}');
    return await body();
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> _loginWithResponse(
  Map<String, dynamic> responseBody, {
  int statusCode = 422,
  AuthService? authService,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    if (request.method != 'POST' || request.uri.path != '/api/v1/auth/login') {
      request.response
        ..statusCode = 404
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Unexpected route'}));
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(responseBody));
    await request.response.close();
  });

  try {
    ApiConfig.setBaseUrl('http://${server.address.host}:${server.port}');
    return await (authService ?? AuthService()).login(
      email: 'user@example.test',
      password: 'password',
      deviceInfo: const {
        'device_id': 'test-device',
        'device_name': 'Test Device',
        'device_type': 'test',
        'os_version': 'test',
        'app_version': 'test',
      },
    );
  } finally {
    await subscription.cancel();
    await server.close(force: true);
  }
}
