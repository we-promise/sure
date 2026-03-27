import 'package:local_auth/local_auth.dart';
import 'log_service.dart';

class BiometricService {
  static final BiometricService instance = BiometricService._();
  BiometricService._();

  final LocalAuthentication _auth = LocalAuthentication();

  /// Returns true when the platform supports biometrics AND at least one
  /// biometric is enrolled on the device.
  Future<bool> isDeviceSupported() async {
    try {
      final isSupported = await _auth.isDeviceSupported();
      if (!isSupported) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Returns the list of enrolled biometric types (fingerprint, face, etc.).
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (_) {
      return [];
    }
  }

  /// Triggers the OS biometric prompt. Returns true if authentication succeeds.
  Future<bool> authenticate({String reason = 'Unlock Sure to continue'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (e, stack) {
      LogService.instance.error('BiometricService', 'authenticate() failed: $e\n$stack');
      return false;
    }
  }
}
