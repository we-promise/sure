import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/account.dart';
import 'api_config.dart';
import 'log_service.dart';

/// Shares account balances and connection details with the iOS home screen
/// widget through the App Group.
///
/// The widget fetches on its own with an API key: either the key the app is
/// logged in with, or a separate (ideally read-only) key saved for the widget.
/// The app's login tokens are never shared, because refreshing them from the
/// widget would log the app out.
class WidgetBridgeService {
  WidgetBridgeService._();
  static final WidgetBridgeService instance = WidgetBridgeService._();

  static const MethodChannel _channel = MethodChannel('am.sure.mobile/widget');
  static const String _widgetApiKeyKey = 'widget_api_key';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool get isSupported => !kIsWeb && Platform.isIOS;

  Future<bool> isAvailable() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> getWidgetApiKey() => _storage.read(key: _widgetApiKeyKey);

  /// Saves (or removes, when empty) the widget's own API key and pushes the
  /// updated connection details to the widget.
  Future<void> setWidgetApiKey(String? apiKey) async {
    final trimmed = apiKey?.trim() ?? '';
    if (trimmed.isEmpty) {
      await _storage.delete(key: _widgetApiKeyKey);
    } else {
      await _storage.write(key: _widgetApiKeyKey, value: trimmed);
    }
    await _send({'config': await _config()});
  }

  /// Re-shares the server URL and key, e.g. after login or a server change.
  Future<void> pushConfig() async {
    if (!isSupported) return;
    await _send({'config': await _config()});
  }

  /// The key the widget will use, if any.
  Future<String?> effectiveApiKey() async {
    final widgetKey = await getWidgetApiKey();
    if (widgetKey != null && widgetKey.isNotEmpty) return widgetKey;
    return ApiConfig.apiKey;
  }

  /// Checks that [apiKey] can read accounts from the configured server.
  Future<String?> testApiKey(String apiKey) async {
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfig.baseUrl}/api/v1/accounts?per_page=1'),
            headers: {
              ...ApiConfig.customProxyHeaderMap,
              'X-Api-Key': apiKey.trim(),
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return null;
      if (response.statusCode == 401 || response.statusCode == 403) {
        return 'The server rejected this API key.';
      }
      return 'Server returned ${response.statusCode}.';
    } catch (_) {
      return 'Could not reach the server.';
    }
  }

  /// Gives the widget the latest balances so it has something to show even
  /// before (or without) fetching on its own.
  Future<void> syncAccounts(List<Account> accounts) async {
    if (!isSupported) return;
    await _send({
      'config': await _config(),
      'snapshot': {
        'updatedAt': _iso8601Seconds(DateTime.now()),
        'accounts': [
          for (final a in accounts)
            if (a.status == null || a.status == 'active')
              {
                'id': a.id,
                'name': a.name,
                'balance': a.balance,
                if (a.balanceCents != null) 'balanceCents': a.balanceCents,
                'currency': a.currency,
                if (a.classification != null) 'classification': a.classification,
                'accountType': a.accountType,
                if (a.institutionName != null) 'institutionName': a.institutionName,
              },
        ],
      },
    });
  }

  /// Removes the balances and connection details the widget can see. The
  /// widget's own key stays in the app's keychain so it is re-shared after the
  /// next login; remove it from the widget settings screen.
  Future<void> clear() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('clear');
    } catch (e) {
      LogService.instance.warning('WidgetBridge', 'clear failed: ${e.runtimeType}');
    }
  }

  Future<Map<String, dynamic>> _config() async {
    final apiKey = await effectiveApiKey();
    return {
      'baseUrl': ApiConfig.baseUrl,
      'headers': ApiConfig.customProxyHeaderMap,
      if (apiKey != null) 'apiKey': apiKey,
    };
  }

  Future<void> _send(Map<String, dynamic> payload) async {
    if (!isSupported) return;
    try {
      // Round-trip through JSON so only plain JSON types cross the channel.
      final plain = jsonDecode(jsonEncode(payload));
      await _channel.invokeMethod('update', plain);
    } catch (e) {
      LogService.instance.warning('WidgetBridge', 'update failed: ${e.runtimeType}');
    }
  }

  /// The widget's decoder expects ISO 8601 without fractional seconds.
  static String _iso8601Seconds(DateTime time) {
    final utc = time.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
        'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }
}
