import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../services/offline_storage_service.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/user_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _groupByType = false;
  String? _appVersion;
  bool _isResettingAccount = false;
  bool _isDeletingAccount = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      final build = packageInfo.buildNumber;
      final display = build.isNotEmpty
          ? '${packageInfo.version} (${build})'
          : packageInfo.version;
      setState(() => _appVersion = display);
    }
  }

  Future<void> _loadPreferences() async {
    final value = await PreferencesService.instance.getGroupByType();
    if (mounted) {
      setState(() {
        _groupByType = value;
      });
    }
  }

  Future<void> _handleClearLocalData(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Local Data'),
        content: const Text(
          'This will delete all locally cached transactions and accounts. '
          'Your data on the server will not be affected. '
          'Are you sure you want to continue?'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear Data'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      try {
        final offlineStorage = OfflineStorageService();
        final log = LogService.instance;

        log.info('Settings', 'Clearing all local data...');
        await offlineStorage.clearAllData();
        log.info('Settings', 'Local data cleared successfully');

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Local data cleared successfully. Pull to refresh to sync from server.'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        final log = LogService.instance;
        log.error('Settings', 'Failed to clear local data: $e');

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to clear local data: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _launchContactUrl(BuildContext context) async {
    final uri = Uri.parse('https://discord.com/invite/36ZGBsxYEK');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open link')),
      );
    }
  }

  Future<void> _handleResetAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Account'),
        content: const Text(
          'Resetting your account will delete all your accounts, categories, '
          'merchants, tags, and other data, but keep your user account intact.\n\n'
          'This action cannot be undone. Are you sure?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Reset Account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _isResettingAccount = true);
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();
      if (accessToken == null) {
        await authProvider.logout();
        return;
      }

      final result = await UserService().resetAccount(accessToken: accessToken);

      if (!context.mounted) return;

      if (result['success'] == true) {
        await OfflineStorageService().clearAllData();

        if (!context.mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account reset has been initiated. This may take a moment.'),
            backgroundColor: Colors.green,
          ),
        );

        await authProvider.logout();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? 'Failed to reset account'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isResettingAccount = false);
    }
  }

  Future<void> _handleDeleteAccount(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Account'),
        content: const Text(
          'Deleting your account will permanently remove all your data '
          'and cannot be undone.\n\n'
          'Are you sure you want to delete your account?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    setState(() => _isDeletingAccount = true);
    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final accessToken = await authProvider.getValidAccessToken();
      if (accessToken == null) {
        await authProvider.logout();
        return;
      }

      final result = await UserService().deleteAccount(accessToken: accessToken);

      if (!context.mounted) return;

      if (result['success'] == true) {
        await authProvider.logout();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? 'Failed to delete account'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  Future<void> _handleLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final authProvider = Provider.of<AuthProvider>(context);

    return Scaffold(
      body: ListView(
        children: [
          // User info section
          Container(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 30,
                          backgroundColor: colorScheme.primary,
                          child: Text(
                            authProvider.user?.displayName[0].toUpperCase() ?? 'U',
                            style: TextStyle(
                              fontSize: 24,
                              color: colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                authProvider.user?.displayName ?? 'User',
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                authProvider.user?.email ?? '',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // App version
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text('App Version: ${_appVersion ?? '…'}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(' > ui_layout: ${authProvider.user?.uiLayout}'),
                Text(' > ai_enabled: ${authProvider.user?.aiEnabled}'),
              ],
            ),
          ),

          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: const Text('Contact us'),
            subtitle: Text(
              'https://discord.com/invite/36ZGBsxYEK',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
            onTap: () => _launchContactUrl(context),
          ),

          const Divider(),

          // Display Settings Section
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Display',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.view_list),
            title: const Text('Group by Account Type'),
            subtitle: const Text('Group accounts by type (Crypto, Bank, etc.)'),
            value: _groupByType,
            onChanged: (value) async {
              await PreferencesService.instance.setGroupByType(value);
              setState(() {
                _groupByType = value;
              });
            },
          ),

          const Divider(),

          // Data Management Section
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Data Management',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),

          // Clear local data button
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Clear Local Data'),
            subtitle: const Text('Remove all cached transactions and accounts'),
            onTap: () => _handleClearLocalData(context),
          ),

          const Divider(),

          // Danger Zone Section
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'Danger Zone',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.red),
            title: const Text('Reset Account'),
            subtitle: const Text(
              'Delete all accounts, categories, merchants, and tags but keep your user account',
            ),
            trailing: _isResettingAccount
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            enabled: !_isResettingAccount && !_isDeletingAccount,
            onTap: _isResettingAccount || _isDeletingAccount ? null : () => _handleResetAccount(context),
          ),

          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Delete Account'),
            subtitle: const Text(
              'Permanently remove all your data. This cannot be undone.',
            ),
            trailing: _isDeletingAccount
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            enabled: !_isDeletingAccount && !_isResettingAccount,
            onTap: _isDeletingAccount || _isResettingAccount ? null : () => _handleDeleteAccount(context),
          ),

          const Divider(),

          // Sign out button
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () => _handleLogout(context),
              icon: const Icon(Icons.logout),
              label: const Text('Sign Out'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colorScheme.error,
                foregroundColor: colorScheme.onError,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
