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
    final raw = await storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return _sanitize(
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
    final sanitized = _sanitize(headers);
    await storage.write(
      key: storageKey,
      value: jsonEncode(sanitized.map((header) => header.toJson()).toList()),
    );
  }

  List<CustomProxyHeader> _sanitize(List<CustomProxyHeader> headers) {
    final byName = <String, CustomProxyHeader>{};
    for (final header in headers) {
      if (!header.isComplete) continue;
      if (CustomProxyHeader.validateName(header.name) != null) continue;
      if (CustomProxyHeader.validateValue(header.value) != null) continue;
      byName[header.normalizedName] = header;
    }
    return byName.values.toList(growable: false);
  }
}
