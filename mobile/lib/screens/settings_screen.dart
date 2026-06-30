import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:upgrader/upgrader.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/auth_provider.dart';
import '../providers/categories_provider.dart';
import '../providers/merchants_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/privacy_provider.dart';
import '../services/offline_storage_service.dart';
import '../services/log_service.dart';
import '../services/biometric_service.dart';
import '../services/preferences_service.dart';
import '../services/user_service.dart';
import 'log_viewer_screen.dart';
import '../models/custom_proxy_header.dart';
import '../services/api_config.dart';
import '../services/custom_proxy_headers_service.dart';
import '../widgets/custom_proxy_headers_editor.dart';
import '../l10n/app_localizations.dart';

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
  bool _biometricSupported = false;
  bool _biometricEnabled = false;
  bool _isTogglingBiometric = false;
  List<CustomProxyHeader> _customHeaders = [];
  bool _isCheckingForUpdate = false;
  late final Upgrader _manualUpgrader;

  String _displayInitial(String? displayName) {
    final trimmed = displayName?.trim() ?? '';
    return trimmed.isEmpty ? 'U' : trimmed[0].toUpperCase();
  }

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _loadAppVersion();
    _loadBiometricState();
    _loadCustomHeaders();
    _manualUpgrader = Upgrader(
      durationUntilAlertAgain: Duration.zero,
      countryCode: 'us',
    );
  }

  Future<void> _checkForUpdate() async {
    if (_isCheckingForUpdate) return;
    setState(() => _isCheckingForUpdate = true);
    try {
      await _manualUpgrader.initialize();
      if (!mounted) {
        _manualUpgrader.dispose();
        return;
      }
      await _manualUpgrader.updateVersionInfo();
      if (!mounted) return;

      final available = _manualUpgrader.isUpdateAvailable();
      final storeVersion = _manualUpgrader.versionInfo?.appStoreVersion?.toString();
      final storeUrl = _manualUpgrader.versionInfo?.appStoreListingURL;

      if (available) {
        await _showUpdateDialog(
          storeVersion ??
              AppLocalizations.of(context).settingsUpdateNewerVersionFallback,
          storeUrl,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).settingsNoUpdateAvailable)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).settingsUpdateError)),
        );
      }
    } finally {
      if (mounted) setState(() => _isCheckingForUpdate = false);
    }
  }

  Future<void> _showUpdateDialog(String version, String? storeUrl) async {
    final launch = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx).settingsUpdateAvailableTitle),
        content: Text(AppLocalizations.of(ctx).settingsUpdateAvailableContent(version)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(ctx).commonCancel),
          ),
          TextButton(
            onPressed: storeUrl == null ? null : () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(ctx).settingsUpdateNow),
          ),
        ],
      ),
    );

    if (launch == true && storeUrl != null && mounted) {
      final uri = Uri.tryParse(storeUrl);
      final opened = uri != null
          ? await launchUrl(uri, mode: LaunchMode.externalApplication)
          : false;
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).settingsUpdateOpenStoreError)),
        );
      }
    }
  }

  @override
  void dispose() {
    _manualUpgrader.dispose();
    super.dispose();
  }

  Future<void> _loadBiometricState() async {
    final supported = await BiometricService.instance.isDeviceSupported();
    final enabled = await PreferencesService.instance.getBiometricEnabled();
    if (!supported && enabled) {
      await PreferencesService.instance.setBiometricEnabled(false);
    }
    if (mounted) {
      setState(() {
        _biometricSupported = supported;
        _biometricEnabled = supported && enabled;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    if (_isTogglingBiometric) return;
    setState(() => _isTogglingBiometric = true);
    try {
      if (value) {
        final success = await BiometricService.instance.authenticate(
          reason: AppLocalizations.of(context).settingsBiometricVerifyReason,
        );
        if (!mounted) return;
        if (!success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).settingsBiometricFailed)),
          );
          return;
        }
      }
      await PreferencesService.instance.setBiometricEnabled(value);
      if (mounted) setState(() => _biometricEnabled = value);
    } finally {
      if (mounted) setState(() => _isTogglingBiometric = false);
    }
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (mounted) {
      final build = packageInfo.buildNumber;
      final display = build.isNotEmpty
          ? '${packageInfo.version} ($build)'
          : packageInfo.version;
      setState(() => _appVersion = display);
    }
  }

  Future<void> _loadPreferences() async {
    final groupByType = await PreferencesService.instance.getGroupByType();
    if (mounted) {
      setState(() {
        _groupByType = groupByType;
      });
    }
  }

  Future<void> _loadCustomHeaders() async {
    try {
      final headers = await CustomProxyHeadersService.instance.loadHeaders();
      if (mounted) {
        setState(() => _customHeaders = headers);
      }
    } catch (e) {
      LogService.instance.warning(
        'SettingsScreen',
        'Failed to load custom headers with ${e.runtimeType}',
      );
      // Keep the existing _customHeaders state so the screen remains usable.
    }
  }

  Future<void> _handleClearLocalData(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AlertDialog(
        title: Text(l.settingsClearDataTitle),
        content: Text(l.settingsClearDataContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l.settingsClearData),
          ),
        ],
      );},
    );

    if (confirmed == true && context.mounted) {
      try {
        final offlineStorage = OfflineStorageService();
        final log = LogService.instance;

        log.info('Settings', 'Clearing all local data...');
        await offlineStorage.clearAllData();
        if (context.mounted) {
          Provider.of<CategoriesProvider>(context, listen: false).clear();
          Provider.of<MerchantsProvider>(context, listen: false).clear();
          Provider.of<TagsProvider>(context, listen: false).clear();
        }
        log.info('Settings', 'Local data cleared successfully');

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.settingsClearDataSuccessDetailed),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        final log = LogService.instance;
        log.error(
          'Settings',
          'Failed to clear local data with ${e.runtimeType}',
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.settingsClearDataFailed),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _launchContactUrl(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final uri = Uri.parse('https://discord.com/invite/36ZGBsxYEK');
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.settingsContactOpenLinkError)),
      );
    }
  }

  Future<void> _handleResetAccount(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dl = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dl.settingsResetAccount),
          content: Text(dl.settingsResetAccountContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dl.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(dl.settingsResetAccount),
            ),
          ],
        );
      },
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
        if (context.mounted) {
          Provider.of<CategoriesProvider>(context, listen: false).clear();
          Provider.of<MerchantsProvider>(context, listen: false).clear();
          Provider.of<TagsProvider>(context, listen: false).clear();
        }

        if (!context.mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.settingsResetAccountInitiated),
            backgroundColor: Colors.green,
          ),
        );

        await authProvider.logout();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? l.settingsResetAccountFailed),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isResettingAccount = false);
    }
  }

  Future<void> _handleDeleteAccount(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dl = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(dl.settingsDeleteAccountTitle),
          content: Text(dl.settingsDeleteAccountConfirmContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(dl.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(dl.settingsDeleteAccount),
            ),
          ],
        );
      },
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

      final result =
          await UserService().deleteAccount(accessToken: accessToken);

      if (!context.mounted) return;

      if (result['success'] == true) {
        await authProvider.logout();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['error'] ?? l.settingsDeleteAccountFailed),
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
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AlertDialog(
        title: Text(l.settingsSignOutTitle),
        content: Text(l.settingsSignOutContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.settingsSignOut),
          ),
        ],
      );},
    );

    if (confirmed == true && context.mounted) {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      await authProvider.logout();
    }
  }

  Future<void> _showCustomHeadersDialog() async {
    final l = AppLocalizations.of(context);
    final formKey = GlobalKey<FormState>();
    final latestHeaders =
        await CustomProxyHeadersService.instance.loadHeaders();
    if (!mounted) return;

    setState(() => _customHeaders = latestHeaders);
    var draftHeaders = List<CustomProxyHeader>.from(latestHeaders);

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        final l = AppLocalizations.of(context);
        return AlertDialog(
          title: Text(l.settingsProxyHeadersLabel),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CustomProxyHeadersEditor(
                    initialHeaders: draftHeaders,
                    onChanged: (headers) => draftHeaders = headers,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.settingsProxyHeadersNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.commonCancel),
            ),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(context, true);
              },
              child: Text(l.commonSave),
            ),
          ],
        );
      },
    );

    if (saved != true) return;

    try {
      await CustomProxyHeadersService.instance.saveHeaders(draftHeaders);
      ApiConfig.setCustomProxyHeaders(draftHeaders);
      if (!mounted) return;
      setState(() => _customHeaders = draftHeaders);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.settingsProxyHeadersSaved)),
      );
    } catch (e) {
      if (!mounted) return;
      LogService.instance.warning(
        'Settings',
        'Failed to save custom proxy headers with ${e.runtimeType}',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.settingsProxyHeadersSaveFailed),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final authProvider = Provider.of<AuthProvider>(context);
    final l = AppLocalizations.of(context);

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
                            _displayInitial(authProvider.user?.displayName),
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
                                authProvider.user?.displayName ?? l.settingsUserFallback,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
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
            title: Text(l.settingsAppVersion(_appVersion ?? '…')),
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
            leading: const Icon(Icons.system_update_outlined),
            title: Text(l.settingsCheckForUpdates),
            subtitle: Text(l.settingsCheckForUpdatesSubtitle),
            trailing: _isCheckingForUpdate
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _isCheckingForUpdate ? null : _checkForUpdate,
          ),

          ListTile(
            leading: const Icon(Icons.chat_bubble_outline),
            title: Text(l.settingsContactUs),
            subtitle: Text(
              'https://discord.com/invite/36ZGBsxYEK',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
            onTap: () => _launchContactUrl(context),
          ),

          Semantics(
            label: l.settingsDebugLogsSemantics,
            button: true,
            child: ListTile(
              leading: const Icon(Icons.bug_report),
              title: Text(l.settingsDebugLogs),
              subtitle: Text(l.settingsDebugLogsSubtitle),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const LogViewerScreen()),
                );
              },
            ),
          ),

          const Divider(),

          // Display Settings Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.settingsSectionDisplay,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),

          SwitchListTile(
            secondary: const Icon(Icons.view_list),
            title: Text(l.settingsGroupByAccountType),
            subtitle: Text(l.settingsGroupByAccountTypeSubtitle),
            value: _groupByType,
            onChanged: (value) async {
              await PreferencesService.instance.setGroupByType(value);
              setState(() {
                _groupByType = value;
              });
            },
          ),

          Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: Text(l.settingsThemeLabel),
                trailing: SegmentedButton<ThemeMode>(
                  segments: [
                    ButtonSegment(
                      value: ThemeMode.light,
                      icon: const Icon(Icons.light_mode, size: 18),
                      tooltip: l.settingsThemeLight,
                    ),
                    ButtonSegment(
                      value: ThemeMode.system,
                      icon: const Icon(Icons.brightness_auto, size: 18),
                      tooltip: l.settingsThemeSystem,
                    ),
                    ButtonSegment(
                      value: ThemeMode.dark,
                      icon: const Icon(Icons.dark_mode, size: 18),
                      tooltip: l.settingsThemeDark,
                    ),
                  ],
                  selected: {themeProvider.themeMode},
                  onSelectionChanged: (modes) =>
                      themeProvider.setThemeMode(modes.first),
                  showSelectedIcon: false,
                ),
              );
            },
          ),

          const Divider(),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.settingsSectionConnection,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.http_outlined),
            title: Text(l.settingsProxyHeadersTileTitle),
            subtitle: Text(
              _customHeaders.isEmpty
                  ? l.settingsProxyHeadersTileSubtitleEmpty
                  : l.settingsProxyHeadersTileSubtitleCount(_customHeaders.length),
            ),
            onTap: _showCustomHeadersDialog,
          ),

          const Divider(),

          // Data Management Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.settingsSectionDataManagement,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),

          // Clear local data button
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l.settingsClearDataTitle),
            subtitle: Text(l.settingsClearDataTileSubtitle),
            onTap: () => _handleClearLocalData(context),
          ),

          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.settingsSectionSecurity,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_outlined),
            title: Text(l.settingsPrivacyHideAmountsLabel),
            subtitle: Text(l.settingsPrivacyHideAmountsContent),
            value: context.watch<PrivacyProvider>().hidden,
            onChanged: (value) =>
                context.read<PrivacyProvider>().setHidden(value),
          ),
          if (_biometricSupported)
            SwitchListTile(
              secondary: const Icon(Icons.fingerprint),
              title: Text(l.settingsBiometricLabel),
              subtitle: Text(l.settingsBiometricEnableContent),
              value: _biometricEnabled,
              onChanged: _isTogglingBiometric ? null : _toggleBiometric,
            ),

          const Divider(),

          // Danger Zone Section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              l.settingsSectionDangerZone,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.red,
              ),
            ),
          ),

          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.red),
            title: Text(l.settingsResetAccount),
            subtitle: Text(l.settingsResetAccountTileSubtitle),
            trailing: _isResettingAccount
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            enabled: !_isResettingAccount && !_isDeletingAccount,
            onTap: _isResettingAccount || _isDeletingAccount
                ? null
                : () => _handleResetAccount(context),
          ),

          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(l.settingsDeleteAccount),
            subtitle: Text(l.settingsDeleteAccountTileSubtitle),
            trailing: _isDeletingAccount
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            enabled: !_isDeletingAccount && !_isResettingAccount,
            onTap: _isDeletingAccount || _isResettingAccount
                ? null
                : () => _handleDeleteAccount(context),
          ),

          const Divider(),

          // Sign out button
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton.icon(
              onPressed: () => _handleLogout(context),
              icon: const Icon(Icons.logout),
              label: Text(l.settingsSignOut),
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
