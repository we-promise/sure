/// App-level configuration for build variants.
class AppConfig {
  AppConfig._();

  /// When true, the app runs as "Companion" with a simplified login
  /// (no API key login, server URL section, or settings access).
  static const bool isCompanion = true;

  /// Comma-separated list of emails allowed to switch environments.
  /// Pass at build time: --dart-define=ALLOWED_ENV_EMAILS=a@x.com,b@x.com
  /// If empty, the environment switcher is hidden for everyone.
  static const String _allowedEnvEmails =
      String.fromEnvironment('ALLOWED_ENV_EMAILS');

  /// Returns true if the given email is allowed to switch environments.
  static bool canSwitchEnvironment(String? email) {
    if (_allowedEnvEmails.isEmpty || email == null || email.isEmpty) {
      return false;
    }
    final allowed = _allowedEnvEmails
        .split(',')
        .map((e) => e.trim().toLowerCase())
        .toSet();
    return allowed.contains(email.toLowerCase());
  }
}
