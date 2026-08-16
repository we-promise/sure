import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../utils/certificate_bytes.dart';

http.Client createHttpClient(List<int>? trustedCertificateBytes) {
  final context = SecurityContext(withTrustedRoots: true);
  if (trustedCertificateBytes != null && trustedCertificateBytes.isNotEmpty) {
    context.setTrustedCertificatesBytes(
      singleCertificateDerBytes(trustedCertificateBytes),
    );
  }
  return IOClient(HttpClient(context: context));
}
