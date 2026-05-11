import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/custom_proxy_header.dart';

class CustomProxyHeadersService {
  static const String storageKey = 'custom_proxy_headers';

  static CustomProxyHeadersService? _instance;

  CustomProxyHeadersService._();

  static CustomProxyHeadersService get instance {
    _instance ??= CustomProxyHeadersService._();
    return _instance!;
  }

  Future<List<CustomProxyHeader>> loadHeaders() async {
    const storage = FlutterSecureStorage();
    try {
      final raw = await storage.read(key: storageKey);
      if (raw == null || raw.isEmpty) return [];

      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return CustomProxyHeader.sanitize(
        decoded
            .whereType<Map>()
            .map((item) => CustomProxyHeader.fromJson(Map<String, dynamic>.from(item)))
            .toList(),
      );
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHeaders(List<CustomProxyHeader> headers) async {
    const storage = FlutterSecureStorage();
    final sanitized = CustomProxyHeader.sanitize(headers);
    await storage.write(
      key: storageKey,
      value: jsonEncode(sanitized.map((header) => header.toJson()).toList()),
    );
  }
}
