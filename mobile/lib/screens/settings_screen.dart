import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/offline_storage_service.dart';
import '../services/log_service.dart';
import '../services/preferences_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _groupByType = false;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
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
            title: const Text('App Version: 0.6.8'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(' > ui_layout: ${authProvider.user?.uiLayout}'),
                Text(' > ai_enabled: ${authProvider.user?.aiEnabled}'),
              ],
            ),
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
