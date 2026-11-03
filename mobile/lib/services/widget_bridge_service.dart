import 'dart:async';
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
///
/// Key changes and channel calls run one at a time, in call order. [clear]
/// bumps [_epoch], and any work started before it is dropped, so no
/// pre-logout write can land after the widget data is cleared.
class WidgetBridgeService {
  WidgetBridgeService._();
  static final WidgetBridgeService instance = WidgetBridgeService._();

  static const MethodChannel _channel = MethodChannel('am.sure.mobile/widget');
  static const String _widgetApiKeyKey = 'widget_api_key';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  int _epoch = 0;
  Future<void> _queue = Future.value();

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
  Future<void> setWidgetApiKey(String? apiKey) {
    final epoch = _epoch;
    final trimmed = apiKey?.trim() ?? '';
    return _enqueue(() async {
      if (epoch != _epoch) return;
      if (trimmed.isEmpty) {
        await _storage.delete(key: _widgetApiKeyKey);
      } else {
        await _storage.write(key: _widgetApiKeyKey, value: trimmed);
      }
      await _update(epoch, () async => {'config': await _config()});
    });
  }

  /// Re-shares the server URL and key, e.g. after login or a server change.
  Future<void> pushConfig() async {
    if (!isSupported) return;
    final epoch = _epoch;
    await _send(epoch, () async => {'config': await _config()});
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
  ///
  /// [fromServer] is false for accounts loaded from the app's offline cache;
  /// those only fill an empty widget and never replace newer data.
  /// [netWorth] is the server-formatted net worth from the balance sheet.
  Future<void> syncAccounts(
    List<Account> accounts, {
    required bool fromServer,
    String? netWorth,
  }) async {
    if (!isSupported) return;
    final epoch = _epoch;
    final updatedAt = fromServer ? DateTime.now() : _latestUpdate(accounts);
    await _send(epoch, () async => {
      'config': await _config(),
      'replaceExisting': fromServer,
      'snapshot': {
        'updatedAt': _iso8601Seconds(updatedAt),
        if (netWorth != null) 'netWorth': netWorth,
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

  /// Logout cleanup: removes the widget's saved key, so it can't be reused by
  /// the next account, and the balances and connection details the widget can
  /// see.
  Future<void> clear() {
    if (!isSupported) return Future.value();
    _epoch++;
    return _enqueue(() async {
      try {
        await _storage.delete(key: _widgetApiKeyKey);
      } catch (e) {
        LogService.instance.warning('WidgetBridge', 'key delete failed: ${e.runtimeType}');
      }
      try {
        await _channel.invokeMethod('clear');
      } catch (e) {
        LogService.instance.warning('WidgetBridge', 'clear failed: ${e.runtimeType}');
      }
    });
  }

  Future<Map<String, dynamic>> _config() async {
    final apiKey = await effectiveApiKey();
    return {
      'baseUrl': ApiConfig.baseUrl,
      'headers': ApiConfig.customProxyHeaderMap,
      if (apiKey != null) 'apiKey': apiKey,
    };
  }

  /// Runs [operation] after everything queued before it. Errors reach the
  /// caller but don't stop later operations.
  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _send(
    int epoch,
    Future<Map<String, dynamic>> Function() buildPayload,
  ) {
    if (!isSupported) return Future.value();
    return _enqueue(() => _update(epoch, buildPayload));
  }

  /// Sends an update unless [clear] ran since [epoch] was read. Must run inside
  /// the queue. The epoch is re-checked after building the payload, because
  /// that reads secure storage.
  Future<void> _update(
    int epoch,
    Future<Map<String, dynamic>> Function() buildPayload,
  ) async {
    if (!isSupported || epoch != _epoch) return;
    try {
      final payload = await buildPayload();
      if (epoch != _epoch) return;
      // Round-trip through JSON so only plain JSON types cross the channel.
      final plain = jsonDecode(jsonEncode(payload));
      await _channel.invokeMethod('update', plain);
    } catch (e) {
      LogService.instance.warning('WidgetBridge', 'update failed: ${e.runtimeType}');
    }
  }

  static DateTime _latestUpdate(List<Account> accounts) {
    DateTime? latest;
    for (final account in accounts) {
      final updated = account.updatedAt;
      if (updated != null && (latest == null || updated.isAfter(latest))) {
        latest = updated;
      }
    }
    return latest ?? DateTime.now();
  }

  /// The widget's decoder expects ISO 8601 without fractional seconds.
  static String _iso8601Seconds(DateTime time) {
    final utc = time.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
        'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
  }
}
