import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/accounts_provider.dart';
import '../services/api_config.dart';
import '../services/widget_bridge_service.dart';
import '../widgets/sure_list_group.dart';

/// Lets the user give the iOS home screen widget an API key so it can fetch
/// balances on its own.
class WidgetSettingsScreen extends StatefulWidget {
  const WidgetSettingsScreen({super.key});

  @override
  State<WidgetSettingsScreen> createState() => _WidgetSettingsScreenState();
}

class _WidgetSettingsScreenState extends State<WidgetSettingsScreen> {
  final _bridge = WidgetBridgeService.instance;
  final _controller = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _available = false;
  bool _hasWidgetKey = false;
  String? _message;
  bool _messageIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final available = await _bridge.isAvailable();
    final key = await _bridge.getWidgetApiKey();
    if (!mounted) return;
    setState(() {
      _available = available;
      _hasWidgetKey = key != null && key.isNotEmpty;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final key = _controller.text.trim();
    if (key.isEmpty) return;
    // Read before testing the key, so a logout during the test drops the save.
    final epoch = _bridge.epoch;
    setState(() {
      _saving = true;
      _message = null;
    });

    var error = await _bridge.testApiKey(key);
    if (error == null) {
      try {
        if (await _bridge.setWidgetApiKey(key, sinceEpoch: epoch)) {
          if (mounted) {
            final provider = Provider.of<AccountsProvider>(context, listen: false);
            final accounts = provider.accounts;
            // With a key saved the widget fetches fresh data itself; this only
            // fills it if it has nothing yet.
            if (accounts.isNotEmpty) {
              await _bridge.syncAccounts(
                accounts,
                fromServer: false,
                netWorth: provider.isBalanceSheetStale ? null : provider.netWorthFormatted,
                sinceEpoch: epoch,
              );
            }
          }
        } else {
          error = epoch == _bridge.epoch
              ? 'The key was saved, but the widget couldn\'t be updated. Try again.'
              : 'You were logged out, so the key wasn\'t saved.';
        }
      } catch (_) {
        error = 'Couldn\'t save the key on this device.';
      }
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      if (error == null) {
        _hasWidgetKey = true;
        _controller.clear();
        _message = 'Saved. The widget will refresh on its own now.';
        _messageIsError = false;
      } else {
        _message = error;
        _messageIsError = true;
      }
    });
  }

  Future<void> _remove() async {
    try {
      await _bridge.setWidgetApiKey(null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = 'Couldn\'t remove the key on this device.';
        _messageIsError = true;
      });
      return;
    }
    // When logged in with an API key, the widget falls back to that key.
    final stillRefreshing = await _bridge.effectiveApiKey() != null;
    if (!mounted) return;
    setState(() {
      _hasWidgetKey = false;
      _message = stillRefreshing
          ? 'Removed. The widget will keep refreshing using the API key you logged in with.'
          : 'Removed. The widget will only show balances from when you last opened the app.';
      _messageIsError = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final usingLoginKey = !_hasWidgetKey && ApiConfig.isApiKeyAuth;

    return Scaffold(
      appBar: AppBar(title: const Text('Home Screen Widget')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (!WidgetBridgeService.widgetAllowsServer(ApiConfig.baseUrl))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        'The widget can only reach this server over HTTPS. Plain HTTP '
                        'works only for IP addresses, .local names and single-word '
                        'hostnames such as http://myserver.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  if (!_available)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        'This build can\'t reach the widget\'s shared storage (App Group). '
                        'Reinstall it with the App Group entitlement.',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  SureListGroup(
                    children: [
                      SureListRow(
                        title: 'Auto refresh',
                        subtitle: _hasWidgetKey
                            ? 'On, using the widget API key'
                            : usingLoginKey
                                ? 'On, using the API key you logged in with'
                                : 'Off. Add an API key below',
                      ),
                      SureListRow(title: 'Server', subtitle: ApiConfig.baseUrl),
                      if (_hasWidgetKey)
                        SureListRow(
                          title: 'Remove widget API key',
                          destructive: true,
                          onTap: _remove,
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Create an API key with Read access in Sure on the web '
                    '(Settings → API Keys) and paste it here. The widget uses it '
                    'to refresh balances without opening the app.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: _hasWidgetKey ? 'Replace widget API key' : 'Widget API key',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Test and save'),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _messageIsError ? theme.colorScheme.error : null,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
