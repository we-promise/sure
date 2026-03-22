import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../services/api_config.dart';

class BackendConfigScreen extends StatefulWidget {
  final VoidCallback? onConfigSaved;

  const BackendConfigScreen({super.key, this.onConfigSaved});

  @override
  State<BackendConfigScreen> createState() => _BackendConfigScreenState();
}

class _BackendConfigScreenState extends State<BackendConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  bool _isLoading = false;
  bool _isTesting = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _loadSavedUrl();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('backend_url');
    final urlToShow = (savedUrl != null && savedUrl.isNotEmpty)
        ? savedUrl
        : ApiConfig.baseUrl;

    if (mounted) {
      setState(() {
        _urlController.text = urlToShow;
      });
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isTesting = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      // Normalize base URL by removing trailing slashes
      final normalizedUrl = _urlController.text.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );

      // Check /sessions/new page to verify it's a Sure backend
      final sessionsUrl = Uri.parse('$normalizedUrl/sessions/new');
      final sessionsResponse = await http
          .get(sessionsUrl, headers: {'Accept': 'text/html'})
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception(
                'Connection timeout. Please check the URL and try again.',
              );
            },
          );

      if (sessionsResponse.statusCode >= 200 &&
          sessionsResponse.statusCode < 400) {
        if (mounted) {
          setState(() {
            _successMessage =
                'Connection successful!';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage =
                'Server responded with status ${sessionsResponse.statusCode}. Please check if this is a Sure backend server.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Connection failed: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  Future<void> _saveAndContinue() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Normalize base URL by removing trailing slashes
      final normalizedUrl = _urlController.text.trim().replaceAll(
        RegExp(r'/+$'),
        '',
      );

      // Save URL to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('backend_url', normalizedUrl);

      // Update ApiConfig
      ApiConfig.setBaseUrl(normalizedUrl);

      // Notify parent that config is saved
      if (mounted && widget.onConfigSaved != null) {
        widget.onConfigSaved!();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to save URL: ${e.toString()}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String? _validateUrl(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a backend URL';
    }

    final trimmedValue = value.trim();

    // Check if it starts with http:// or https://
    if (!trimmedValue.startsWith('http://') &&
        !trimmedValue.startsWith('https://')) {
      return 'URL must start with http:// or https://';
    }

    // Basic URL validation
    try {
      final uri = Uri.parse(trimmedValue);
      if (!uri.hasScheme || uri.host.isEmpty) {
        return 'Please enter a valid URL';
      }
    } catch (e) {
      return 'Please enter a valid URL';
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 48),
                // Logo/Title
                Icon(
                  Icons.settings_outlined,
                  size: 80,
                  color: colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Configuration',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.primary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Update your Sure server URL',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),

                // Info box
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.info_outline, color: colorScheme.primary),
                          const SizedBox(width: 12),
                          Text(
                            'Example URLs',
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '• https://demo.sure.am\n'
                        '• https://your-domain.com\n'
                        '• http://localhost:3000',
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Error Message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: colorScheme.error),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _errorMessage = null;
                            });
                          },
                          iconSize: 20,
                        ),
                      ],
                    ),
                  ),

                // Success Message
                if (_successMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.green),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_outline,
                          color: Colors.green,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _successMessage!,
                            style: TextStyle(color: Colors.green[800]),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            setState(() {
                              _successMessage = null;
                            });
                          },
                          iconSize: 20,
                        ),
                      ],
                    ),
                  ),

                // URL Field
                TextFormField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Sure server URL',
                    prefixIcon: Icon(Icons.cloud_outlined),
                    hintText: 'https://app.sure.am',
                  ),
                  validator: _validateUrl,
                  onFieldSubmitted: (_) => _saveAndContinue(),
                ),
                const SizedBox(height: 16),

                // Test Connection Button
                OutlinedButton.icon(
                  onPressed: _isTesting || _isLoading ? null : _testConnection,
                  icon: _isTesting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cable),
                  label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
                ),

                const SizedBox(height: 12),

                // Continue Button
                ElevatedButton(
                  onPressed: _isLoading || _isTesting ? null : _saveAndContinue,
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),

                const SizedBox(height: 24),

                // Info text
                Text(
                  'You can change this later in the settings.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
