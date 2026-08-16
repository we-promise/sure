import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sure_mobile/services/custom_certificate_service.dart';
import 'package:sure_mobile/services/http_client_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('saves and loads a custom CA certificate and its name', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    await CustomCertificateService.instance.saveCertificate(
      bytes,
      'root.crt',
    );

    expect(
      await CustomCertificateService.instance.loadCertificate(),
      orderedEquals(bytes),
    );
    expect(
      await CustomCertificateService.instance.loadCertificateName(),
      'root.crt',
    );
  });

  test('clears a saved custom CA certificate', () async {
    await CustomCertificateService.instance.saveCertificate(
      Uint8List.fromList([1, 2, 3]),
      'root.crt',
    );

    await CustomCertificateService.instance.clearCertificate();

    expect(await CustomCertificateService.instance.loadCertificate(), isNull);
    expect(
      await CustomCertificateService.instance.loadCertificateName(),
      isNull,
    );
  });

  test('rejects bytes that are not an X.509 certificate', () {
    expect(
      () => createHttpClient([1, 2, 3]),
      throwsA(anything),
    );
  });

  test('rejects oversized certificate storage', () async {
    expect(
      () => CustomCertificateService.instance.saveCertificate(
        Uint8List(CustomCertificateService.maxCertificateBytes + 1),
        'root.crt',
      ),
      throwsFormatException,
    );
  });
}
