import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sure_mobile/utils/certificate_bytes.dart';
import 'package:sure_mobile/utils/certificate_fingerprint.dart';

void main() {
  test('formats a SHA-256 certificate fingerprint', () {
    expect(
      certificateSha256Fingerprint([1, 2, 3]),
      '03:90:58:C6:F2:C0:CB:49:2C:53:3B:0A:4D:14:EF:77:'
      'CC:0F:78:AB:CC:CE:D5:28:7D:84:A1:A2:01:1C:FB:81',
    );
  });

  test('PEM and DER representations have the same fingerprint', () {
    final der = [1, 2, 3];
    final pem = utf8.encode(
      '-----BEGIN CERTIFICATE-----\n'
      '${base64Encode(der)}\n'
      '-----END CERTIFICATE-----\n',
    );

    expect(
      certificateSha256Fingerprint(pem),
      certificateSha256Fingerprint(der),
    );
  });

  test('rejects certificate bundles', () {
    const certificate =
        '-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n';

    expect(
      () => singleCertificateDerBytes(utf8.encode('$certificate$certificate')),
      throwsFormatException,
    );
  });
}
