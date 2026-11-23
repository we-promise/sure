import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image_picker/image_picker.dart';
import 'package:sure_mobile/services/receipts_service.dart';

void main() {
  XFile photo(String name) =>
      XFile.fromData(Uint8List.fromList([0xFF, 0xD8, 0xFF]), name: name, path: '/photos/$name', mimeType: 'image/jpeg');

  group('ReceiptsService', () {
    test('uploads account_id and every photo as files[]', () async {
      late http.Request sent;
      final service = ReceiptsService(
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'id': 'scan_1',
              'status': 'processing',
              'account_id': 'acct_1',
              'transaction_id': 'tx_1',
              'review_reasons': [],
            }),
            202,
          );
        }),
      );

      final scan = await service.upload(
        accessToken: 'token',
        accountId: 'acct_1',
        files: [photo('a.jpg'), photo('b.jpg')],
      );

      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/v1/receipts');
      expect(sent.headers['content-type'], startsWith('multipart/form-data'));
      final body = utf8.decode(sent.bodyBytes, allowMalformed: true);
      expect(body, contains('name="account_id"'));
      expect('name="files[]"'.allMatches(body).length, 2);
      expect(body, contains('filename="a.jpg"'));
      expect(scan.id, 'scan_1');
      expect(scan.status, 'processing');
      expect(scan.transactionId, 'tx_1');
    });

    test('sends picker photos without a mime type as image/jpeg', () async {
      late http.Request sent;
      final service = ReceiptsService(
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'id': 's', 'status': 'processing', 'account_id': 'a'}), 202);
        }),
      );

      await service.upload(
        accessToken: 'token',
        accountId: 'a',
        files: [XFile.fromData(Uint8List.fromList([0xFF, 0xD8]), path: '/tmp/image_picker_123.jpg')],
      );

      expect(utf8.decode(sent.bodyBytes, allowMalformed: true), contains('content-type: image/jpeg'));
    });

    test('names a photo without a file name', () async {
      late http.Request sent;
      final service = ReceiptsService(
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'id': 's', 'status': 'processing', 'account_id': 'a'}), 202);
        }),
      );

      await service.upload(
        accessToken: 'token',
        accountId: 'a',
        files: [XFile.fromData(Uint8List.fromList([1]), mimeType: 'image/jpeg')],
      );

      expect(utf8.decode(sent.bodyBytes, allowMalformed: true), contains('filename="receipt-1.jpg"'));
    });

    test('maps a 422 message to ReceiptUploadException', () async {
      final service = ReceiptsService(
        client: MockClient((_) async => http.Response(
              jsonEncode({'error': 'validation_failed', 'message': 'A receipt can have at most 5 files.'}),
              422,
            )),
      );

      expect(
        () => service.upload(accessToken: 'token', accountId: 'acct_1', files: [photo('a.jpg')]),
        throwsA(isA<ReceiptUploadException>()
            .having((e) => e.message, 'message', 'A receipt can have at most 5 files.')),
      );
    });
  });
}
