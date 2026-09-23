import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

class CustomCertificateService {
  CustomCertificateService._();

  static final CustomCertificateService instance = CustomCertificateService._();
  static const String _certificateKey = 'custom_ca_certificate';
  static const String _certificateNameKey = 'custom_ca_certificate_name';
  static const int maxCertificateBytes = 64 * 1024;

  Future<Uint8List?> loadCertificate() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = prefs.getString(_certificateKey);
    if (encoded == null || encoded.isEmpty) return null;
    return base64Decode(encoded);
  }

  Future<String?> loadCertificateName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_certificateNameKey);
  }

  Future<void> saveCertificate(Uint8List bytes, String name) async {
    if (bytes.isEmpty || bytes.length > maxCertificateBytes) {
      throw const FormatException('Invalid certificate file size.');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_certificateKey, base64Encode(bytes));
    await prefs.setString(_certificateNameKey, name);
  }

  Future<void> clearCertificate() async {
    final prefs = await SharedPreferences.getInstance();
    final certificateRemoved = !prefs.containsKey(_certificateKey) ||
        await prefs.remove(_certificateKey);
    final certificateNameRemoved = !prefs.containsKey(_certificateNameKey) ||
        await prefs.remove(_certificateNameKey);
    if (!certificateRemoved || !certificateNameRemoved) {
      throw StateError('Failed to clear the custom CA certificate.');
    }
  }
}
