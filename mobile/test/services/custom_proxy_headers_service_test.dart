import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sure_mobile/models/custom_proxy_header.dart';
import 'package:sure_mobile/services/custom_proxy_headers_service.dart';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('saves and loads custom proxy headers', () async {
    final service = CustomProxyHeadersService.instance;
    final headers = [
      CustomProxyHeader(name: 'X-Auth-Id', value: 'id'),
      CustomProxyHeader(name: 'X-Auth-Secret', value: 'secret'),
    ];

    await service.saveHeaders(headers);

    expect(await service.loadHeaders(), headers);
  });

  test('drops incomplete and duplicate headers, keeping the last value', () async {
    final service = CustomProxyHeadersService.instance;

    await service.saveHeaders([
      CustomProxyHeader(name: 'X-Auth-Id', value: 'old'),
      CustomProxyHeader(name: '', value: 'ignored'),
      CustomProxyHeader(name: 'X-Auth-Id', value: 'new'),
      CustomProxyHeader(name: 'X-Empty', value: ''),
    ]);

    expect(await service.loadHeaders(), [
      CustomProxyHeader(name: 'X-Auth-Id', value: 'new'),
    ]);
  });

  test('returns an empty list for invalid stored json', () async {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: CustomProxyHeadersService.storageKey,
      value: 'not json',
    );

    expect(await CustomProxyHeadersService.instance.loadHeaders(), isEmpty);
  });
}
