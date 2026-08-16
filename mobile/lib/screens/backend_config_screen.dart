import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/custom_proxy_header.dart';
import '../services/api_http_client.dart';
import '../services/api_config.dart';
import '../services/custom_certificate_service.dart';
import '../services/custom_proxy_headers_service.dart';
import '../services/log_service.dart';
import '../utils/certificate_fingerprint.dart';
import '../widgets/custom_proxy_headers_editor.dart';
import '../l10n/app_localizations.dart';

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
  bool _hasLoadedConfig = false;
  String? _errorMessage;
  String? _successMessage;
  List<CustomProxyHeader> _customHeaders = [];
  Uint8List? _certificateBytes;
  String? _certificateName;

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
    String urlToShow = ApiConfig.baseUrl;
    List<CustomProxyHeader> headers = const [];
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('backend_url');
      headers = await CustomProxyHeadersService.instance.loadHeaders();
      _certificateBytes =
          await CustomCertificateService.instance.loadCertificate();
      _certificateName =
          await CustomCertificateService.instance.loadCertificateName();
      if (savedUrl != null && savedUrl.isNotEmpty) {
        urlToShow = savedUrl;
      }
    } catch (e) {
      // Swallow storage failures so the screen still becomes interactive with
      // sensible defaults; the user can re-enter and re-save.
      LogService.instance.warning(
        'BackendConfigScreen',
        'Failed to load saved backend config with ${e.runtimeType}',
      );
    } finally {
      if (mounted) {
        setState(() {
          _urlController.text = urlToShow;
          _customHeaders = headers;
          _hasLoadedConfig = true;
        });
      }
    }
  }

  Future<void> _pickCertificate() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pem', 'crt', 'cer', 'der'],
        withData: true,
      );
      if (result == null) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null ||
          bytes.isEmpty ||
          bytes.length > CustomCertificateService.maxCertificateBytes) {
        throw const FormatException('Certificate is empty');
      }

      // Building the client validates that Dart can parse the selected file.
      ApiHttpClient.instance.configure(
        trustedCertificateBytes: bytes,
        trustedOrigin: Uri.parse(ApiConfig.baseUrl),
      );
      ApiHttpClient.instance.configure(
        trustedCertificateBytes: ApiConfig.customCertificateBytes,
        trustedOrigin: ApiConfig.customCertificateBytes == null
            ? null
            : Uri.parse(ApiConfig.baseUrl),
      );
      if (mounted) {
        setState(() {
          _certificateBytes = bytes;
          _certificateName = file.name;
          _errorMessage = null;
        });
      }
    } catch (e) {
      ApiHttpClient.instance.configure(
        trustedCertificateBytes: ApiConfig.customCertificateBytes,
        trustedOrigin: ApiConfig.customCertificateBytes == null
            ? null
            : Uri.parse(ApiConfig.baseUrl),
      );
      if (mounted) {
        setState(() {
          _errorMessage =
              AppLocalizations.of(context).backendConfigCertificateInvalid;
        });
      }
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    final l = AppLocalizations.of(context);

    setState(() {
      _isTesting = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final previousHeaders = ApiConfig.customProxyHeaders;
    final previousCertificate = ApiConfig.customCertificateBytes;
    try {
      // Normalize base URL by removing trailing slashes
      final normalizedUrl = _urlController.text.trim().replaceAll(
            RegExp(r'/+$'),
            '',
          );

      // Apply the unsaved edits only for the duration of this probe so the
      // test reflects what the user is about to save. Restored in `finally`.
      ApiConfig.setCustomProxyHeaders(_customHeaders);
      ApiHttpClient.instance.configure(
        trustedCertificateBytes: _certificateBytes,
        trustedOrigin:
            _certificateBytes == null ? null : Uri.parse(normalizedUrl),
      );

      // Check /sessions/new page to verify it's a Sure backend
      final sessionsUrl = Uri.parse('$normalizedUrl/sessions/new');
      final sessionsResponse = await ApiHttpClient.instance
          .get(sessionsUrl, headers: ApiConfig.htmlHeaders())
          .timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception(l.backendConfigTimeout);
        },
      );

      if (sessionsResponse.statusCode >= 200 &&
          sessionsResponse.statusCode < 400) {
        if (mounted) {
          setState(() {
            _successMessage = l.backendConfigSuccess;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage =
                l.backendConfigServerError(sessionsResponse.statusCode);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = l.backendConfigConnectionFailed(e.toString());
        });
      }
    } finally {
      ApiConfig.setCustomProxyHeaders(previousHeaders);
      ApiHttpClient.instance.configure(
        trustedCertificateBytes: previousCertificate,
        trustedOrigin:
            previousCertificate == null ? null : Uri.parse(ApiConfig.baseUrl),
      );
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  Future<void> _saveAndContinue() async {
    if (!_formKey.currentState!.validate()) return;

    final l = AppLocalizations.of(context);

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

      // Save custom proxy headers
      await CustomProxyHeadersService.instance.saveHeaders(_customHeaders);
      ApiConfig.setCustomProxyHeaders(_customHeaders);

      if (_certificateBytes == null) {
        await CustomCertificateService.instance.clearCertificate();
      } else {
        await CustomCertificateService.instance.saveCertificate(
          _certificateBytes!,
          _certificateName ?? 'certificate',
        );
      }
      ApiConfig.setCustomCertificate(
        _certificateBytes,
        name: _certificateName,
      );

      // Update ApiConfig
      ApiConfig.setBaseUrl(normalizedUrl);

      // Notify parent that config is saved
      if (mounted && widget.onConfigSaved != null) {
        widget.onConfigSaved!();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = l.backendConfigSaveFailed(e.toString());
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

  String? _validateUrl(String? value, AppLocalizations l) {
    if (value == null || value.isEmpty) {
      return l.backendConfigUrlRequired;
    }

    final trimmedValue = value.trim();

    // Check if it starts with http:// or https://
    if (!trimmedValue.startsWith('http://') &&
        !trimmedValue.startsWith('https://')) {
      return l.backendConfigUrlScheme;
    }

    // Basic URL validation
    try {
      final uri = Uri.parse(trimmedValue);
      if (!uri.hasScheme || uri.host.isEmpty) {
        return l.backendConfigUrlInvalid;
      }
    } catch (e) {
      return l.backendConfigUrlInvalid;
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
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
                  l.backendConfigTitle,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l.backendConfigSubtitle,
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
                            l.backendConfigExampleUrlsLabel,
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
                  decoration: InputDecoration(
                    labelText: l.backendConfigUrlLabel,
                    prefixIcon: const Icon(Icons.cloud_outlined),
                    hintText: l.backendConfigUrlHint,
                  ),
                  validator: (value) => _validateUrl(value, l),
                  onFieldSubmitted: (_) => _saveAndContinue(),
                ),
                const SizedBox(height: 24),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: const Icon(Icons.http_outlined),
                  title: Text(l.backendConfigProxyHeadersLabel),
                  subtitle: Text(
                    _customHeaders.isEmpty
                        ? l.backendConfigProxyHeadersSubtitle
                        : l.backendConfigProxyHeadersCount(
                            _customHeaders.length),
                  ),
                  children: [
                    const SizedBox(height: 8),
                    if (_hasLoadedConfig)
                      CustomProxyHeadersEditor(
                        initialHeaders: _customHeaders,
                        onChanged: (headers) {
                          setState(() => _customHeaders = headers);
                        },
                      )
                    else
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      l.backendConfigHeadersHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  leading: const Icon(Icons.verified_user_outlined),
                  title: Text(l.backendConfigCertificateLabel),
                  subtitle: Text(
                    _certificateName ?? l.backendConfigCertificateSubtitle,
                  ),
                  children: [
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isLoading || _isTesting
                                ? null
                                : _pickCertificate,
                            icon: const Icon(Icons.upload_file_outlined),
                            label: Text(l.backendConfigCertificateChoose),
                          ),
                        ),
                        if (_certificateBytes != null) ...[
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: l.backendConfigCertificateRemove,
                            onPressed: _isLoading || _isTesting
                                ? null
                                : () => setState(() {
                                      _certificateBytes = null;
                                      _certificateName = null;
                                    }),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.backendConfigCertificateHelp,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                    if (_certificateBytes != null) ...[
                      const SizedBox(height: 12),
                      SelectableText(
                        l.backendConfigCertificateFingerprint(
                          certificateSha256Fingerprint(_certificateBytes!),
                        ),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                              fontFamily: 'monospace',
                            ),
                      ),
                    ],
                  ],
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
                  label: Text(_isTesting
                      ? l.backendConfigTesting
                      : l.backendConfigTestButton),
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
                      : Text(l.backendConfigContinueButton),
                ),

                const SizedBox(height: 24),

                // Info text
                Text(
                  l.backendConfigChangeHint,
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
