import 'package:crypto/crypto.dart';

import 'certificate_bytes.dart';

String certificateSha256Fingerprint(List<int> bytes) {
  return sha256
      .convert(singleCertificateDerBytes(bytes))
      .bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}
