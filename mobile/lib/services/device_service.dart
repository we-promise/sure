import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DeviceService {
  static const String _deviceIdKey = 'device_id';
  
  Future<Map<String, String>> getDeviceInfo() async {
    final prefs = await SharedPreferences.getInstance();
    final packageInfo = await PackageInfo.fromPlatform();

    // Get or generate device ID
    String? deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = _generateDeviceId();
      await prefs.setString(_deviceIdKey, deviceId);
    }

    return {
      'device_id': deviceId,
      'device_name': _getDeviceName(),
      'device_type': _getDeviceType(),
      'os_version': _getOsVersion(),
      'app_version': packageInfo.version,
    };
  }

  String _generateDeviceId() {
    // Generate a unique device ID
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = timestamp.toString().hashCode.abs();
    return 'sure_mobile_${timestamp}_$random';
  }

  String _getDeviceName() {
    if (kIsWeb) {
      return 'Web Browser';
    }
    try {
      if (Platform.isAndroid) {
        return 'Android Device';
      } else if (Platform.isIOS) {
        return 'iOS Device';
      }
    } catch (e) {
      // Platform not available
    }
    return 'Mobile Device';
  }

  String _getDeviceType() {
    if (kIsWeb) {
      return 'web';
    }
    try {
      if (Platform.isAndroid) {
        return 'android';
      } else if (Platform.isIOS) {
        return 'ios';
      }
    } catch (e) {
      // Platform not available
    }
    return 'unknown';
  }

  String _getOsVersion() {
    if (kIsWeb) {
      return 'web';
    }
    try {
      return Platform.operatingSystemVersion;
    } catch (e) {
      return 'unknown';
    }
  }
}
