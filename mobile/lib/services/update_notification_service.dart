import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateNotificationService {
  static const _notificationId = 42;
  static const _prefKey = 'last_update_notified_version';
  static const _packageId = 'am.sure.mobile';
  static const _playStoreUrl = 'https://play.google.com/store/apps/details?id=$_packageId';

  final _notifications = FlutterLocalNotificationsPlugin();

  Future<void> initialize(BuildContext context) async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _notifications.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _onTap,
    );

    final plugin = _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (plugin == null) return;

    final granted = await plugin.areNotificationsEnabled() ?? false;
    if (granted) return;

    if (!context.mounted) return;
    final proceed = await _showRationale(context);
    if (proceed) await plugin.requestNotificationsPermission();
  }

  Future<bool> _showRationale(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Stay up to date'),
        content: const Text(
          'Allow Sure to send you notifications so you know '
          'when a new version is available.\n\n'
          'If you deny, you won\'t be notified about updates and may miss '
          'important improvements or bug fixes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> checkAndNotify() async {
    final storeVersion = await _fetchPlayStoreVersion();
    if (storeVersion == null) return;

    final packageInfo = await PackageInfo.fromPlatform();
    if (!_isNewer(storeVersion, packageInfo.version)) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_prefKey) == storeVersion) return;

    await _fire(storeVersion);
    await prefs.setString(_prefKey, storeVersion);
  }

  Future<String?> _fetchPlayStoreVersion() async {
    try {
      final url = Uri.parse('$_playStoreUrl&hl=en');
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final match = RegExp(r'\[\[\["(\d+\.\d+\.\d+)"').firstMatch(response.body);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  bool _isNewer(String store, String installed) {
    final s = store.split('.').map(int.tryParse).toList();
    final i = installed.split('.').map(int.tryParse).toList();
    for (var idx = 0; idx < 3; idx++) {
      final sv = idx < s.length ? (s[idx] ?? 0) : 0;
      final iv = idx < i.length ? (i[idx] ?? 0) : 0;
      if (sv > iv) return true;
      if (sv < iv) return false;
    }
    return false;
  }

  Future<void> _fire(String version) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'app_updates',
        'App Updates',
        channelDescription: 'Notifications for new app versions',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(),
    );
    await _notifications.show(
      _notificationId,
      'New version available',
      'Sure $version is available on the Play Store.',
      details,
    );
  }

  static void _onTap(NotificationResponse _) {
    launchUrl(Uri.parse(_playStoreUrl), mode: LaunchMode.externalApplication);
  }
}
