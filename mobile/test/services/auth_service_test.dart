import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:sure_mobile/services/auth_service.dart';

void main() {
  group('AuthService', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ApiConfig.clearApiKeyAuth();
      ApiConfig.setCustomProxyHeaders([]);
      ApiConfig.setBaseUrl('http://${server.address.host}:${server.port}');
    });

    tearDown(() async {
      ApiConfig.setBaseUrl(ApiConfig.defaultBaseUrl);
      await server.close(force: true);
    });

    test('login handles string errors payloads without throwing', () async {
      final subscription = server.listen((request) {
        if (request.method != 'POST' ||
            request.uri.path != '/api/v1/auth/login') {
          request.response.statusCode = 404;
          request.response.close();
          return;
        }

        request.response
          ..statusCode = 422
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'errors': 'Invalid login payload'}))
          ..close();
      });
      addTearDown(subscription.cancel);

      final result = await AuthService().login(
        email: 'user@example.test',
        password: 'password',
        deviceInfo: const {'platform': 'test'},
      );

      expect(result['success'], false);
      expect(result['error'], 'Invalid login payload');
    });
  });
}
