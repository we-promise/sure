import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/models/custom_proxy_header.dart';
import 'package:sure_mobile/services/api_config.dart';
import 'package:sure_mobile/services/custom_certificate_service.dart';
import 'package:sure_mobile/services/custom_proxy_headers_service.dart';

const _testCertificate = '''-----BEGIN CERTIFICATE-----
MIIDCzCCAfOgAwIBAgIUYwH24ykcHjfxpMXCLk0aHtS05OgwDQYJKoZIhvcNAQEL
BQAwFTETMBEGA1UEAwwKU3VyZVRlc3RDQTAeFw0yNjA4MTYxMjM5MTdaFw0zNjA4
MTMxMjM5MTdaMBUxEzARBgNVBAMMClN1cmVUZXN0Q0EwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDTndxmBmrmTcWrhTuXYA3OAssHy8kPBA/gvBiH4qqx
fWentvfVZIYMKacMK+WZV8IRhT0FagrcIpOZCmVTiYsBAEgBniOdulhmxRYwuXun
zJON64e0pRtkh4EIrKpLo7nmaZbGKiqAa8TlZD2eTiQdQmPTHhwCsvkEgolbwL2a
QouWrM5HuqAKIo8vY0vgUFsZJ3oBOhnS4GgF3yNAG/Io2VxCnT5N3u9iAZ43m/Rm
H3uK40HP2IEswJGXCubkkJ9cz87LVk1oYN2BtgoEIBL805iPnvZB65OtChW3FQuS
+bVOo8tuW4utmtJBw50kRqFJfQvHofnEB77py9+Ij1uVAgMBAAGjUzBRMB0GA1Ud
DgQWBBTQEoa1hFrJq2caeCIZ7q7uyAUGpzAfBgNVHSMEGDAWgBTQEoa1hFrJq2ca
eCIZ7q7uyAUGpzAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQCg
lr8iJ0tL88Clr6xaHoz8jiWt+ptUMPbJcfaQxO6R6dGYyTQUJH69tXherajQEi2H
E6PCfNlcwqW4ECykDhMjhNWeViCtniSK0MqAS3zPrOtV5Jn+nXKhcCEX0V/mz+ez
wd51PYjwsYnwb/aBmMr3Wx7vrORNCZp5Xu7VolU9d4Nst1XtaCqfsmOldUGD/suF
lyP4oFC2ywYoHvFDafqCGmimC6vXZ5X6RGB9w3zb1+82MMXJ+rwYO6QRj/Haxv4a
mkX6NHRWnz+vrOnZ/8l8DuaZNzlEuJajlF7zyoyTQqcfJSOpGi8v/nlgsEVWLwfJ
csiFOYYAoev9iP+b0a0w
-----END CERTIFICATE-----''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ApiConfig.applyBackendConfiguration(
      baseUrl: ApiConfig.defaultBaseUrl,
      customProxyHeaders: const [],
      customCertificateBytes: null,
    );
  });

  for (var completedWrites = 0; completedWrites <= 3; completedWrites++) {
    test(
      'recovers an interrupted update after $completedWrites data writes',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('backend_url', 'https://old.example');
        await CustomCertificateService.instance.saveCertificate(
          Uint8List.fromList([1, 2, 3]),
          'old.crt',
        );
        await CustomProxyHeadersService.instance.saveHeaders([
          CustomProxyHeader(name: 'X-Config', value: 'old'),
        ]);

        await ApiConfig.beginBackendConfigUpdate(prefs);
        if (completedWrites >= 1) {
          await CustomCertificateService.instance.saveCertificate(
            Uint8List.fromList([4, 5, 6]),
            'new.crt',
          );
        }
        if (completedWrites >= 2) {
          await CustomProxyHeadersService.instance.saveHeaders([
            CustomProxyHeader(name: 'X-Config', value: 'new'),
          ]);
        }
        if (completedWrites >= 3) {
          await prefs.setString('backend_url', 'https://new.example');
        }

        await ApiConfig.initialize();

        expect(ApiConfig.baseUrl, ApiConfig.defaultBaseUrl);
        expect(ApiConfig.customCertificateBytes, isNull);
        expect(ApiConfig.customProxyHeaders, isEmpty);
        expect(prefs.getString('backend_url'), ApiConfig.defaultBaseUrl);
        expect(
          prefs.containsKey(ApiConfig.backendConfigUpdatePendingKey),
          isFalse,
        );
        expect(
          await CustomCertificateService.instance.loadCertificate(),
          isNull,
        );
        expect(
          await CustomCertificateService.instance.loadCertificateName(),
          isNull,
        );
        expect(
          await CustomProxyHeadersService.instance.loadHeaders(),
          isEmpty,
        );
      },
    );
  }

  test('setBaseUrl does not publish a URL when transport validation fails', () {
    ApiConfig.applyBackendConfiguration(
      baseUrl: 'https://old.example',
      customProxyHeaders: const [],
      customCertificateBytes: utf8.encode(_testCertificate),
      customCertificateName: 'root.crt',
    );

    expect(
      () => ApiConfig.setBaseUrl('http://new.example'),
      throwsArgumentError,
    );
    expect(ApiConfig.baseUrl, 'https://old.example');
  });
}
