import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sure_mobile/services/api_http_client.dart';

void main() {
  group('sameOrigin', () {
    test('matches the same HTTPS host and effective port', () {
      expect(
        sameOrigin(
          Uri.parse('https://sure.example/api/v1/accounts'),
          Uri.parse('https://SURE.example:443'),
        ),
        isTrue,
      );
    });

    test('rejects a different host, scheme, or port', () {
      final origin = Uri.parse('https://sure.example:8443');

      expect(
        sameOrigin(Uri.parse('https://other.example:8443'), origin),
        isFalse,
      );
      expect(
        sameOrigin(Uri.parse('http://sure.example:8443'), origin),
        isFalse,
      );
      expect(
        sameOrigin(Uri.parse('https://sure.example:443'), origin),
        isFalse,
      );
    });
  });

  group('ApiHttpClient', () {
    test('uses custom trust only for the configured origin', () async {
      var systemRequests = 0;
      var customRequests = 0;
      final client = ApiHttpClient.forTesting(
        systemDelegate: MockClient((request) async {
          systemRequests += 1;
          return http.Response('system', 200);
        }),
        customClientFactory: (_) => MockClient((request) async {
          customRequests += 1;
          return http.Response('custom', 200);
        }),
      );
      client.configure(
        trustedCertificateBytes: [1],
        trustedOrigin: Uri.parse('https://sure.example'),
      );

      final trusted = await client.get(
        Uri.parse('https://sure.example/api/v1/accounts'),
      );
      final other = await client.get(
        Uri.parse('https://other.example/api/v1/accounts'),
      );

      expect(trusted.body, 'custom');
      expect(other.body, 'system');
      expect(customRequests, 1);
      expect(systemRequests, 1);
    });

    test('disables automatic redirects on the custom-trust transport',
        () async {
      bool? followsRedirects;
      final client = ApiHttpClient.forTesting(
        systemDelegate: MockClient((_) async => http.Response('', 500)),
        customClientFactory: (_) => MockClient((request) async {
          followsRedirects = request.followRedirects;
          return http.Response('', 302,
              headers: {'location': 'https://evil.test'});
        }),
      );
      client.configure(
        trustedCertificateBytes: [1],
        trustedOrigin: Uri.parse('https://sure.example'),
      );

      final response = await client.get(Uri.parse('https://sure.example'));

      expect(response.statusCode, 302);
      expect(followsRedirects, isFalse);
    });

    test('requires an origin whenever custom trust is configured', () {
      final client = ApiHttpClient.forTesting(
        systemDelegate: MockClient((_) async => http.Response('', 200)),
        customClientFactory: (_) => MockClient(
          (_) async => http.Response('', 200),
        ),
      );

      expect(
        () => client.configure(trustedCertificateBytes: [1]),
        throwsArgumentError,
      );
    });

    test('requires HTTPS whenever custom trust is configured', () {
      final client = ApiHttpClient.forTesting(
        systemDelegate: MockClient((_) async => http.Response('', 200)),
        customClientFactory: (_) => MockClient(
          (_) async => http.Response('', 200),
        ),
      );

      expect(
        () => client.configure(
          trustedCertificateBytes: [1],
          trustedOrigin: Uri.parse('http://sure.example'),
        ),
        throwsArgumentError,
      );
    });
  });
}
