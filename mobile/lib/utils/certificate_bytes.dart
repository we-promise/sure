import 'dart:convert';
import 'dart:typed_data';

final _pemCertificatePattern = RegExp(
  r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
);

/// Returns one DER-encoded certificate, rejecting PEM bundles and extra data.
Uint8List singleCertificateDerBytes(List<int> bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return Uint8List.fromList(bytes);
  }

  final matches = _pemCertificatePattern.allMatches(text).toList();
  if (matches.isEmpty) return Uint8List.fromList(bytes);
  if (matches.length != 1 ||
      text.replaceFirst(_pemCertificatePattern, '').trim().isNotEmpty) {
    throw const FormatException(
      'Select a file containing exactly one CA certificate.',
    );
  }

  final encoded = matches.single.group(1)!.replaceAll(RegExp(r'\s'), '');
  return base64Decode(encoded);
}

/// Returns one PEM-encoded certificate for platforms whose security context
/// accepts PEM or PKCS#12 rather than a bare DER certificate.
Uint8List singleCertificatePemBytes(List<int> bytes) {
  final encoded = base64Encode(singleCertificateDerBytes(bytes));
  final lines = <String>[];
  for (var offset = 0; offset < encoded.length; offset += 64) {
    final end = offset + 64 < encoded.length ? offset + 64 : encoded.length;
    lines.add(encoded.substring(offset, end));
  }
  return Uint8List.fromList(
    utf8.encode(
      '-----BEGIN CERTIFICATE-----\n'
      '${lines.join('\n')}\n'
      '-----END CERTIFICATE-----\n',
    ),
  );
}
