import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
/// bumps [epoch], and any work started before it is dropped, so no
/// pre-logout write can land after the widget data is cleared. Callers that
/// await something slow (a server fetch, a key test) before writing read
/// [epoch] first and pass it in, so a logout in between still cancels them.
class WidgetBridgeService {
  WidgetBridgeService._();
  static final WidgetBridgeService instance = WidgetBridgeService._();

  static const MethodChannel _channel = MethodChannel('am.sure.mobile/widget');
  static const String _widgetApiKeyKey = 'widget_api_key';

  /// Set when logout couldn't delete the widget key, so the next account never
  /// uses it. Cleared once the key is deleted or replaced.
  static const String _keyRevokedPref = 'widget_api_key_revoked';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  int _epoch = 0;
  bool _keyRevoked = false;
  Future<void> _queue = Future.value();

  /// Changes on every logout. Read it before slow work and pass it to the
  /// write that follows.
  int get epoch => _epoch;

  /// The widget extension needs iOS 17 (WidgetKit app intents), while the app
  /// itself still runs on iOS 15.
  bool get isSupported =>
      !kIsWeb && Platform.isIOS && iosMajorVersion(Platform.operatingSystemVersion) >= 17;

  /// Reads the major iOS version from [Platform.operatingSystemVersion], e.g.
  /// "Version 17.4.1 (Build 21E236)" or "17.4.1". Returns 0 if it can't tell.
  @visibleForTesting
  static int iosMajorVersion(String osVersion) {
    final match = RegExp(r'(\d+)(?:\.\d+)*').firstMatch(osVersion);
    return match == null ? 0 : int.parse(match.group(1)!);
  }

  Future<bool> isAvailable() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The widget's own API key, unless logout couldn't delete it.
  Future<String?> getWidgetApiKey() async {
    if (await _isKeyRevoked()) return null;
    final key = await _storage.read(key: _widgetApiKeyKey);
    return key == null || key.isEmpty ? null : key;
  }

  /// Saves (or removes, when empty) the widget's own API key and pushes the
  /// updated connection details to the widget.
  ///
  /// Returns false if the key couldn't be stored or the widget couldn't be
  /// updated. Nothing is written if a logout happened after [sinceEpoch]
  /// (defaults to now).
  Future<bool> setWidgetApiKey(String? apiKey, {int? sinceEpoch}) {
    final epoch = sinceEpoch ?? _epoch;
    final trimmed = apiKey?.trim() ?? '';
    return _enqueue(() async {
      if (epoch != _epoch) return false;
      if (trimmed.isEmpty) {
        await _storage.delete(key: _widgetApiKeyKey);
      } else {
        await _storage.write(key: _widgetApiKeyKey, value: trimmed);
      }
      await _setKeyRevoked(false);
      return _update(epoch, () async => {'config': await _config()});
    });
  }

  /// Re-shares the server URL and key, e.g. after login or a server change.
  Future<void> pushConfig({int? sinceEpoch}) async {
    if (!isSupported) return;
    await _send(sinceEpoch ?? _epoch, () async => {'config': await _config()});
  }

  /// Whether the widget can connect to [baseUrl]. The widget extension
  /// enforces App Transport Security, which allows plain HTTP only to IP
  /// addresses, `.local` names and unqualified hostnames.
  static bool widgetAllowsServer(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null) return false;
    if (uri.scheme == 'https') return true;
    final host = uri.host;
    return InternetAddress.tryParse(host) != null ||
        host.endsWith('.local') ||
        !host.contains('.');
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
  /// Pass the [epoch] read before fetching as [sinceEpoch], so accounts fetched
  /// before a logout are dropped.
  Future<void> syncAccounts(
    List<Account> accounts, {
    required bool fromServer,
    String? netWorth,
    int? sinceEpoch,
  }) async {
    if (!isSupported) return;
    final epoch = sinceEpoch ?? _epoch;
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
  ///
  /// If the key can't be deleted it is marked revoked instead, and
  /// [getWidgetApiKey] ignores it until a new key is saved. The native side
  /// invalidates the widget files before deleting them and reports failure,
  /// in which case it is tried once more.
  Future<void> clear() {
    if (!isSupported) return Future.value();
    _epoch++;
    return _enqueue(() async {
      try {
        await _storage.delete(key: _widgetApiKeyKey);
        if (_keyRevoked) await _setKeyRevoked(false);
      } catch (e) {
        LogService.instance.warning('WidgetBridge', 'key delete failed: ${e.runtimeType}');
        _keyRevoked = true;
        try {
          await _setKeyRevoked(true);
        } catch (e) {
          LogService.instance.warning('WidgetBridge', 'key revoke failed: ${e.runtimeType}');
        }
      }
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          if (await _channel.invokeMethod<bool>('clear') == true) return;
        } catch (e) {
          LogService.instance.warning('WidgetBridge', 'clear failed: ${e.runtimeType}');
        }
      }
      LogService.instance.warning('WidgetBridge', 'widget data could not be invalidated');
    });
  }

  Future<bool> _isKeyRevoked() async {
    if (_keyRevoked) return true;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_keyRevokedPref) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _setKeyRevoked(bool revoked) async {
    _keyRevoked = revoked;
    final prefs = await SharedPreferences.getInstance();
    if (revoked) {
      await prefs.setBool(_keyRevokedPref, true);
    } else {
      await prefs.remove(_keyRevokedPref);
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

  /// Runs [operation] after everything queued before it. Errors reach the
  /// caller but don't stop later operations.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _send(
    int epoch,
    Future<Map<String, dynamic>> Function() buildPayload,
  ) async {
    if (!isSupported) return;
    await _enqueue(() => _update(epoch, buildPayload));
  }

  /// Sends an update unless [clear] ran since [epoch] was read. Must run inside
  /// the queue. The epoch is re-checked after building the payload, because
  /// that reads secure storage. Returns whether the widget files were written.
  Future<bool> _update(
    int epoch,
    Future<Map<String, dynamic>> Function() buildPayload,
  ) async {
    if (!isSupported || epoch != _epoch) return false;
    try {
      final payload = await buildPayload();
      if (epoch != _epoch) return false;
      // Round-trip through JSON so only plain JSON types cross the channel.
      final plain = jsonDecode(jsonEncode(payload));
      final written = await _channel.invokeMethod<bool>('update', plain) ?? false;
      if (!written) LogService.instance.warning('WidgetBridge', 'update not written');
      return written;
    } catch (e) {
      LogService.instance.warning('WidgetBridge', 'update failed: ${e.runtimeType}');
      return false;
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
