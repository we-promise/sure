import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../providers/auth_provider.dart';
import '../l10n/app_localizations.dart';

class SsoOnboardingScreen extends StatefulWidget {
  const SsoOnboardingScreen({super.key});

  @override
  State<SsoOnboardingScreen> createState() => _SsoOnboardingScreenState();
}

class _SsoOnboardingScreenState extends State<SsoOnboardingScreen> {
  bool _showLinkForm = true;
  final _linkFormKey = GlobalKey<FormState>();
  final _createFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    _emailController.text = authProvider.ssoEmail ?? '';
    _firstNameController.text = authProvider.ssoFirstName ?? '';
    _lastNameController.text = authProvider.ssoLastName ?? '';
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    super.dispose();
  }

  Future<void> _handleLinkAccount() async {
    if (!_linkFormKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    await authProvider.ssoLinkAccount(
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );
  }

  Future<void> _handleCreateAccount() async {
    if (!_createFormKey.currentState!.validate()) return;

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    await authProvider.ssoCreateAccount(
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Provider.of<AuthProvider>(context, listen: false)
                .cancelSsoOnboarding();
          },
        ),
        title: Text(AppLocalizations.of(context).ssoOnboardingTitle),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Consumer<AuthProvider>(
            builder: (context, authProvider, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Header
                  SvgPicture.asset(
                    'assets/images/google_g_logo.svg',
                    width: 48,
                    height: 48,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    authProvider.ssoEmail != null
                        ? AppLocalizations.of(context)
                            .ssoOnboardingSignedInAs(authProvider.ssoEmail!)
                        : AppLocalizations.of(context)
                            .ssoOnboardingGoogleVerified,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 24),

                  // Error message
                  if (authProvider.errorMessage != null)
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
                    ),

                  // Tab selector
                  if (authProvider.ssoAllowAccountCreation) ...[
                    Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _TabButton(
                              label: AppLocalizations.of(context).ssoOnboardingTabLink,
                              isSelected: _showLinkForm,
                              onTap: () =>
                                  setState(() => _showLinkForm = true),
                            ),
                          ),
                          Expanded(
                            child: _TabButton(
                              label: authProvider.ssoHasPendingInvitation
                                  ? AppLocalizations.of(context).ssoOnboardingAcceptInvitation
                                  : AppLocalizations.of(context).ssoOnboardingTabCreate,
                              isSelected: !_showLinkForm,
                              onTap: () =>
                                  setState(() => _showLinkForm = false),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Link existing account form
                  if (_showLinkForm) _buildLinkForm(authProvider, colorScheme),

                  // Create new account form
                  if (!_showLinkForm)
                    _buildCreateForm(authProvider, colorScheme),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLinkForm(AuthProvider authProvider, ColorScheme colorScheme) {
    return Form(
      key: _linkFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.link, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)
                        .ssoOnboardingLinkCredentialsNote,
                    style: TextStyle(color: colorScheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).loginEmailLabel,
              prefixIcon: const Icon(Icons.email_outlined),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return AppLocalizations.of(context).loginEmailRequired;
              if (!value.contains('@')) return AppLocalizations.of(context).loginEmailInvalid;
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).loginPasswordLabel,
              prefixIcon: const Icon(Icons.lock_outlined),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () {
                  setState(() => _obscurePassword = !_obscurePassword);
                },
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return AppLocalizations.of(context).loginPasswordRequired;
              return null;
            },
            onFieldSubmitted: (_) => _handleLinkAccount(),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: authProvider.isLoading ? null : _handleLinkAccount,
            child: authProvider.isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(AppLocalizations.of(context).ssoOnboardingLinkButton),
          ),
        ],
      ),
    );
  }

  Widget _buildCreateForm(AuthProvider authProvider, ColorScheme colorScheme) {
    final hasPendingInvitation = authProvider.ssoHasPendingInvitation;
    return Form(
      key: _createFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  hasPendingInvitation ? Icons.mail_outline : Icons.person_add,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasPendingInvitation
                        ? AppLocalizations.of(context)
                            .ssoOnboardingPendingInvitationNote
                        : AppLocalizations.of(context)
                            .ssoOnboardingCreateIdentityNote,
                    style: TextStyle(color: colorScheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _firstNameController,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).ssoOnboardingFirstNameLabel,
              prefixIcon: const Icon(Icons.person_outlined),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return AppLocalizations.of(context).ssoOnboardingFirstNameRequired;
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _lastNameController,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context).ssoOnboardingLastNameLabel,
              prefixIcon: const Icon(Icons.person_outlined),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) return AppLocalizations.of(context).ssoOnboardingLastNameRequired;
              return null;
            },
            onFieldSubmitted: (_) => _handleCreateAccount(),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: authProvider.isLoading ? null : _handleCreateAccount,
            child: authProvider.isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(hasPendingInvitation
                        ? AppLocalizations.of(context).ssoOnboardingAcceptInvitation
                        : AppLocalizations.of(context).ssoOnboardingCreateButton),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? colorScheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isSelected ? colorScheme.onPrimary : colorScheme.onSurface,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
