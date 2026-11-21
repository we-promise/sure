import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/auth_service.dart';
import '../theme/sure_colors.dart';
import '../theme/sure_spacing.dart';
import '../widgets/password_reset_error_message.dart';
import '../widgets/sure_button.dart';
import '../widgets/sure_text_field.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, this.authService});

  final AuthService? authService;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  late final AuthService _authService = widget.authService ?? AuthService();
  bool _isLoading = false;
  bool _submitted = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading || !_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await _authService.requestPasswordReset(
      email: _emailController.text.trim(),
    );
    if (!mounted) return;

    final l = AppLocalizations.of(context);
    if (result['success'] == true) {
      setState(() {
        _isLoading = false;
        _submitted = true;
      });
      return;
    }

    setState(() {
      _isLoading = false;
      _errorMessage = result['rateLimited'] == true
          ? l.forgotPasswordRateLimitedError
          : result['retryable'] == true
              ? l.forgotPasswordNetworkError
              : l.forgotPasswordGenericError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.forgotPasswordTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SureSpacing.xxxl),
          child: _submitted ? _buildConfirmation(l) : _buildForm(l),
        ),
      ),
    );
  }

  Widget _buildForm(AppLocalizations l) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: SureSpacing.xl),
          Text(
            l.forgotPasswordInstructions,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: SureColors.of(context).palette.textSecondary,
                ),
          ),
          const SizedBox(height: SureSpacing.huge),
          if (_errorMessage != null) ...[
            PasswordResetErrorMessage(message: _errorMessage!),
            const SizedBox(height: SureSpacing.xl),
          ],
          SureTextField(
            controller: _emailController,
            label: l.forgotPasswordEmailLabel,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.email],
            prefixIcon: const Icon(Icons.email_outlined),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return l.forgotPasswordEmailRequired;
              }
              if (!value.contains('@')) return l.forgotPasswordEmailInvalid;
              return null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: SureSpacing.xxxl),
          SureButton(
            label: l.forgotPasswordSendLink,
            size: SureButtonSize.lg,
            fullWidth: true,
            loading: _isLoading,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmation(AppLocalizations l) {
    final palette = SureColors.of(context).palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: SureSpacing.huge),
        Icon(Icons.mark_email_read_outlined, size: 64, color: palette.success),
        const SizedBox(height: SureSpacing.xxxl),
        Text(
          l.forgotPasswordConfirmationTitle,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: SureSpacing.lg),
        Text(
          l.forgotPasswordConfirmationMessage,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: palette.textSecondary,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: SureSpacing.huge),
        SureButton(
          label: l.forgotPasswordBackToSignIn,
          variant: SureButtonVariant.ghost,
          fullWidth: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
