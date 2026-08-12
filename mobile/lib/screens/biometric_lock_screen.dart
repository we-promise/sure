import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/biometric_service.dart';

class BiometricLockScreen extends StatefulWidget {
  const BiometricLockScreen({
    super.key,
    required this.onUnlocked,
    this.onLogout,
  });

  final VoidCallback onUnlocked;
  final VoidCallback? onLogout;

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    // Auto-trigger biometric prompt on first show.
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    if (!mounted || _isAuthenticating) return;
    setState(() => _isAuthenticating = true);

    final success = await BiometricService.instance.authenticate();

    if (!mounted) return;
    setState(() => _isAuthenticating = false);

    if (success) {
      widget.onUnlocked();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).biometricLockFailedRetry)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline,
                size: 72,
                color: colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                l.biometricTitle,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                l.biometricSubtitle,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 40),
              FilledButton.icon(
                onPressed: _isAuthenticating ? null : _authenticate,
                icon: const Icon(Icons.fingerprint),
                label: Text(_isAuthenticating ? l.biometricAuthenticating : l.biometricUnlock),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(200, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (widget.onLogout != null) ...[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: widget.onLogout,
                  child: Text(l.biometricLogOut),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
