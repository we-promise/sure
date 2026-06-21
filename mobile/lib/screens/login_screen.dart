import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../providers/auth_provider.dart';
import '../services/api_config.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_logo.dart';
import 'backend_config_screen.dart';
import '../l10n/app_localizations.dart';

class LoginScreen extends StatefulWidget {
  final VoidCallback? onGoToSettings;

  const LoginScreen({super.key, this.onGoToSettings});

  void _openSettings(BuildContext context) {
    if (onGoToSettings != null) {
      onGoToSettings!();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => BackendConfigScreen(
          onConfigSaved: () => Navigator.of(routeContext).pop(),
        ),
      ),
    );
  }

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  static const _emailPlaceholder = 'user@example.com';
  static const _passwordPlaceholder = 'Password1!';
  final _emailController = TextEditingController(text: _emailPlaceholder);
  final _passwordController = TextEditingController(text: _passwordPlaceholder);
  final _otpController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _obscurePassword = true;
  late final TapGestureRecognizer _signUpTapRecognizer;

  @override
  void initState() {
    super.initState();
    _signUpTapRecognizer = TapGestureRecognizer()..onTap = _openSignUpPage;
    _emailFocus.addListener(() => _clearPlaceholderOnFocus(
          _emailFocus, _emailController, _emailPlaceholder));
    _passwordFocus.addListener(() => _clearPlaceholderOnFocus(
          _passwordFocus, _passwordController, _passwordPlaceholder));
  }

  void _clearPlaceholderOnFocus(
      FocusNode node, TextEditingController controller, String placeholder) {
    if (node.hasFocus && controller.text == placeholder) {
      controller.clear();
    }
  }

  @override
  void dispose() {
    _signUpTapRecognizer.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _openSignUpPage() async {
    final l = AppLocalizations.of(context);
    final signUpUrl = Uri.parse('${ApiConfig.defaultBaseUrl}/registration/new');
    final launched = await launchUrl(
      signUpUrl,
      mode: LaunchMode.externalApplication,
    );

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.loginSignUpOpenError)),
      );
    }
  }

  void _showApiKeyDialog() {
    final apiKeyController = TextEditingController();
    final outerContext = context;
    bool isLoading = false;

    showDialog(
      context: context,
      builder: (dialogContext) {
        final dl = AppLocalizations.of(dialogContext);
        return StatefulBuilder(
          builder: (_, setDialogState) {
            return AlertDialog(
              title: Text(dl.loginApiKeyDialogTitle),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    dl.loginApiKeyDialogBody,
                    style:
                        Theme.of(outerContext).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(outerContext)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: apiKeyController,
                    decoration: InputDecoration(
                      labelText: dl.loginApiKeyLabel,
                      prefixIcon: const Icon(Icons.vpn_key_outlined),
                    ),
                    obscureText: true,
                    maxLines: 1,
                    enabled: !isLoading,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isLoading
                      ? null
                      : () {
                          apiKeyController.dispose();
                          Navigator.of(dialogContext).pop();
                        },
                  child: Text(dl.commonCancel),
                ),
                ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : () async {
                          final apiKey = apiKeyController.text.trim();
                          if (apiKey.isEmpty) return;

                          setDialogState(() {
                            isLoading = true;
                          });

                          final authProvider = Provider.of<AuthProvider>(
                            outerContext,
                            listen: false,
                          );
                          final success = await authProvider.loginWithApiKey(
                            apiKey: apiKey,
                          );

                          if (!dialogContext.mounted) return;

                          final errorMsg = authProvider.errorMessage;
                          apiKeyController.dispose();
                          Navigator.of(dialogContext).pop();

                          if (!success && mounted) {
                            ScaffoldMessenger.of(outerContext).showSnackBar(
                              SnackBar(
                                content: Text(
                                  errorMsg ?? dl.loginApiKeyInvalid,
                                ),
                                backgroundColor:
                                    Theme.of(outerContext).colorScheme.error,
                              ),
                            );
                          }
                        },
                  child: isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(dl.loginApiKeySignIn),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final hadOtpCode =
        authProvider.showMfaInput && _otpController.text.isNotEmpty;

    final success = await authProvider.login(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      otpCode: authProvider.showMfaInput ? _otpController.text.trim() : null,
    );

    // Check if widget is still mounted after async operation
    if (!mounted) return;

    // Clear OTP field if login failed and user had entered an OTP code
    // This allows user to easily try again with a new code
    if (!success && hadOtpCode && authProvider.errorMessage != null) {
      _otpController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l = AppLocalizations.of(context);

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 48),
                    // Logo/Title
                    const SureLogo(size: 80),
                    const SizedBox(height: 24),
                    Text.rich(
                      TextSpan(
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                        children: [
                          TextSpan(text: l.loginDemoOrSignUpPrefix),
                          TextSpan(
                            text: l.loginSignUpLink,
                            style: TextStyle(
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                            recognizer: _signUpTapRecognizer,
                          ),
                          TextSpan(text: l.loginSignUpSuffix),
                        ],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 48),

                    // Error Message
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        if (authProvider.errorMessage != null) {
                          return Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.error_outline,
                                  color: colorScheme.error,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    authProvider.errorMessage!,
                                    style: TextStyle(
                                        color: colorScheme.onErrorContainer),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close),
                                  onPressed: () => authProvider.clearError(),
                                  iconSize: 20,
                                ),
                              ],
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),

                    // Email Field
                    TextFormField(
                      controller: _emailController,
                      focusNode: _emailFocus,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: l.loginEmailLabel,
                        prefixIcon: const Icon(Icons.email_outlined),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return l.loginEmailRequired;
                        }
                        if (!value.contains('@')) {
                          return l.loginEmailInvalid;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    // Password and OTP Fields with Consumer
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        final showOtp = authProvider.showMfaInput;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Password Field
                            TextFormField(
                              controller: _passwordController,
                              focusNode: _passwordFocus,
                              obscureText: _obscurePassword,
                              textInputAction: showOtp
                                  ? TextInputAction.next
                                  : TextInputAction.done,
                              decoration: InputDecoration(
                                labelText: l.loginPasswordLabel,
                                prefixIcon: const Icon(Icons.lock_outlined),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
                                ),
                              ),
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return l.loginPasswordRequired;
                                }
                                return null;
                              },
                              onFieldSubmitted:
                                  showOtp ? null : (_) => _handleLogin(),
                            ),

                            // OTP Field (shown when MFA is required)
                            if (showOtp) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: colorScheme.primaryContainer
                                      .withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.security,
                                      color: colorScheme.primary,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        l.loginMfaInfo,
                                        style: TextStyle(
                                            color: colorScheme.onSurface),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                controller: _otpController,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.done,
                                decoration: InputDecoration(
                                  labelText: l.loginMfaLabel,
                                  prefixIcon: const Icon(Icons.pin_outlined),
                                ),
                                validator: (value) {
                                  if (showOtp &&
                                      (value == null || value.isEmpty)) {
                                    return l.loginMfaCodeRequired;
                                  }
                                  return null;
                                },
                                onFieldSubmitted: (_) => _handleLogin(),
                              ),
                            ],
                          ],
                        );
                      },
                    ),

                    const SizedBox(height: 24),

                    // Login Button
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        return SureButton(
                          label: l.loginSignIn,
                          size: SureButtonSize.lg,
                          fullWidth: true,
                          loading: authProvider.isLoading,
                          onPressed: _handleLogin,
                        );
                      },
                    ),

                    const SizedBox(height: 16),

                    // Divider with "or"
                    Row(
                      children: [
                        Expanded(
                            child: Divider(color: colorScheme.outlineVariant)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            l.loginOrDivider,
                            style:
                                TextStyle(color: colorScheme.onSurfaceVariant),
                          ),
                        ),
                        Expanded(
                            child: Divider(color: colorScheme.outlineVariant)),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // Google Sign-In button
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        return SureButton(
                          label: l.loginSignInWithGoogle,
                          variant: SureButtonVariant.outline,
                          size: SureButtonSize.lg,
                          fullWidth: true,
                          leading: SvgPicture.asset(
                            'assets/images/google_g_logo.svg',
                            width: 18,
                            height: 18,
                          ),
                          onPressed: authProvider.isLoading
                              ? null
                              : () =>
                                  authProvider.startSsoLogin('google_oauth2'),
                        );
                      },
                    ),

                    const SizedBox(height: 24),

                    // Backend URL info
                    InkWell(
                      onTap: () => widget._openSettings(context),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          children: [
                            Text(
                              l.loginServerUrlHeading,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                        fontWeight: FontWeight.bold,
                                      ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              ApiConfig.baseUrl,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: colorScheme.primary,
                                        fontFamily: 'monospace',
                                      ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),

                    // API Key Login Button
                    Consumer<AuthProvider>(
                      builder: (context, authProvider, _) {
                        return SureButton(
                          label: l.loginApiKeyLoginButton,
                          variant: SureButtonVariant.ghost,
                          onPressed:
                              authProvider.isLoading ? null : _showApiKeyDialog,
                          leading:
                              const Icon(Icons.vpn_key_outlined, size: 18),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: l.loginBackendSettingsTooltip,
                onPressed: () => widget._openSettings(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
