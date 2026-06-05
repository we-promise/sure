import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:sure_mobile/services/auth_service.dart';

void main() {
  group('AuthService', () {
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
  });
}

Future<Map<String, dynamic>> _loginWithResponse(
  Map<String, dynamic> responseBody,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((request) async {
    if (request.method != 'POST' ||
        request.uri.path != '/api/v1/auth/login') {
      request.response
        ..statusCode = 404
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'Unexpected route'}));
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = 422
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(responseBody));
    await request.response.close();
  });

  try {
    ApiConfig.setBaseUrl('http://${server.address.host}:${server.port}');
    return await AuthService().login(
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
