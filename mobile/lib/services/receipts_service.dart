import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import '../models/receipt_scan.dart';
import 'api_config.dart';
import 'transactions_service.dart';

class ReceiptUploadException implements Exception {
  final String message;
  final bool unauthorized;

  const ReceiptUploadException(this.message, {this.unauthorized = false});

  @override
  String toString() => message;
}

/// Uploads receipt photos; the server creates a transaction and reads the
/// receipt in the background.
class ReceiptsService {
  final http.Client _client;

  ReceiptsService({http.Client? client}) : _client = client ?? http.Client();

  Future<ReceiptScan> upload({
    required String accessToken,
    required String accountId,
    required List<XFile> files,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('${ApiConfig.baseUrl}/api/v1/receipts'))
      ..headers.addAll(ApiConfig.getAuthHeaders(accessToken))
      ..fields['account_id'] = accountId;

    for (final (index, file) in files.indexed) {
      request.files.add(http.MultipartFile.fromBytes(
        'files[]',
        await file.readAsBytes(),
        filename: file.name.isNotEmpty ? file.name : 'receipt-${index + 1}.jpg',
        contentType: _mediaType(file),
      ));
    }

    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 60)),
    );

    if (response.statusCode == 202 || response.statusCode == 200) {
      return ReceiptScan.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
    }
    if (response.statusCode == 401) {
      throw const ReceiptUploadException('unauthorized', unauthorized: true);
    }
    throw ReceiptUploadException(TransactionsService.errorMessageFromResponseBody(
      response.body,
      fallback: 'Failed to upload receipt',
    ));
  }

  // image_picker hands back files without a MIME type on iOS and Android, and
  // re-encodes photos to JPEG; infer from the extension, defaulting to JPEG.
  static http.MediaType _mediaType(XFile file) {
    final mime = file.mimeType;
    if (mime != null && mime.contains('/')) {
      final parts = mime.split('/');
      return http.MediaType(parts[0], parts[1]);
    }
    final name = (file.name.isNotEmpty ? file.name : file.path).toLowerCase();
    if (name.endsWith('.png')) return http.MediaType('image', 'png');
    if (name.endsWith('.webp')) return http.MediaType('image', 'webp');
    if (name.endsWith('.heic')) return http.MediaType('image', 'heic');
    if (name.endsWith('.pdf')) return http.MediaType('application', 'pdf');
    return http.MediaType('image', 'jpeg');
  }
}
