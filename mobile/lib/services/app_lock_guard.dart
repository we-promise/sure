/// Decides when the biometric lock comes back on.
///
/// Native screens the app opens itself (the document scanner, the photo
/// picker) send it to the background as far as the operating system is
/// concerned. Locking then would ask for Face ID again the moment the user
/// returns from scanning a receipt, so while such a screen is open going to
/// the background doesn't lock. If the app stays away longer than [grace]
/// (the user left it with the scanner open, say), it locks on return.
class AppLockGuard {
  static const grace = Duration(minutes: 5);
  static final instance = AppLockGuard();

  AppLockGuard({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int _openNativeScreens = 0;
  DateTime? _leftAt;

  /// Runs [action], which shows a native screen, without locking the app
  /// while that screen is open.
  Future<T> whileNativeScreenOpen<T>(Future<T> Function() action) async {
    _openNativeScreens++;
    try {
      return await action();
    } finally {
      _openNativeScreens--;
    }
  }

  /// Called when the app goes to the background; true when it should lock now.
  bool shouldLockOnPause() {
    if (_openNativeScreens == 0) return true;
    _leftAt ??= _clock();
    return false;
  }

  /// Called when the app comes back; true when a native screen kept it away
  /// for longer than [grace].
  bool shouldLockOnResume() {
    final leftAt = _leftAt;
    _leftAt = null;
    return leftAt != null && _clock().difference(leftAt) > grace;
  }
}
