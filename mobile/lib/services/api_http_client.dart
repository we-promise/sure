import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'http_client_factory.dart';

/// Shared API client whose trust store can include the user's private CA.
///
/// Platform trust roots remain enabled, and hostname verification is not
/// bypassed when a custom certificate is configured.
class ApiHttpClient extends http.BaseClient {
  ApiHttpClient._()
      : _systemDelegate = createHttpClient(null),
        _customClientFactory = createHttpClient;

  @visibleForTesting
  ApiHttpClient.forTesting({
    required http.Client systemDelegate,
    required http.Client Function(List<int>) customClientFactory,
  })  : _systemDelegate = systemDelegate,
        _customClientFactory = customClientFactory;

  static final ApiHttpClient instance = ApiHttpClient._();

  final http.Client _systemDelegate;
  final http.Client Function(List<int>) _customClientFactory;
  http.Client? _customDelegate;
  Uri? _trustedOrigin;

  void configure({
    List<int>? trustedCertificateBytes,
    Uri? trustedOrigin,
  }) {
    if (trustedCertificateBytes != null) {
      if (trustedOrigin == null) {
        throw ArgumentError(
          'A trusted origin is required with a custom certificate.',
        );
      }
      if (trustedOrigin.scheme.toLowerCase() != 'https') {
        throw ArgumentError(
          'Custom certificates can only be used with HTTPS origins.',
        );
      }
    }

    final replacement = trustedCertificateBytes == null
        ? null
        : _customClientFactory(trustedCertificateBytes);
    final previous = _customDelegate;
    _customDelegate = replacement;
    _trustedOrigin = trustedCertificateBytes == null ? null : trustedOrigin;
    previous?.close();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final customDelegate = _customDelegate;
    final trustedOrigin = _trustedOrigin;
    if (customDelegate != null &&
        trustedOrigin != null &&
        sameOrigin(request.url, trustedOrigin)) {
      // Prevent the custom trust context from following redirects to another
      // origin. A later request to another host uses system trust instead.
      request.followRedirects = false;
      return customDelegate.send(request);
    }
    return _systemDelegate.send(request);
  }

  @override
  void close() {
    // This process-wide client must not be closed by an individual service.
  }
}

bool sameOrigin(Uri first, Uri second) {
  return first.scheme.toLowerCase() == second.scheme.toLowerCase() &&
      first.host.toLowerCase() == second.host.toLowerCase() &&
      first.port == second.port;
}
