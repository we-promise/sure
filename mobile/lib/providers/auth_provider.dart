import 'package:flutter/foundation.dart';
import '../models/user.dart';
import '../models/auth_tokens.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';

class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final DeviceService _deviceService = DeviceService();
  
  User? _user;
  AuthTokens? _tokens;
  bool _isLoading = true;
  String? _errorMessage;
  bool _mfaRequired = false;

  User? get user => _user;
  AuthTokens? get tokens => _tokens;
  bool get isLoading => _isLoading;
  bool get isAuthenticated => _tokens != null && !_tokens!.isExpired;
  String? get errorMessage => _errorMessage;
  bool get mfaRequired => _mfaRequired;

  AuthProvider() {
    _loadStoredAuth();
  }

  Future<void> _loadStoredAuth() async {
    _isLoading = true;
    notifyListeners();

    try {
      _tokens = await _authService.getStoredTokens();
      _user = await _authService.getStoredUser();

      // If tokens exist but are expired, try to refresh
      if (_tokens != null && _tokens!.isExpired) {
        await _refreshToken();
      }
    } catch (e) {
      _tokens = null;
      _user = null;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> login({
    required String email,
    required String password,
    String? otpCode,
  }) async {
    _errorMessage = null;
    _mfaRequired = false;
    _isLoading = true;
    notifyListeners();

    try {
      final deviceInfo = await _deviceService.getDeviceInfo();
      final result = await _authService.login(
        email: email,
        password: password,
        deviceInfo: deviceInfo,
        otpCode: otpCode,
      );

      debugPrint('Login result: $result'); // Debug log

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        if (result['mfa_required'] == true) {
          _mfaRequired = true;
          debugPrint('MFA required! _mfaRequired set to: $_mfaRequired'); // Debug log
          // Don't show error message when MFA is required - it's a normal flow
          _errorMessage = null;
        } else {
          _errorMessage = result['error'] as String?;
        }
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Connection error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> signup({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    String? inviteCode,
  }) async {
    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final deviceInfo = await _deviceService.getDeviceInfo();
      final result = await _authService.signup(
        email: email,
        password: password,
        firstName: firstName,
        lastName: lastName,
        deviceInfo: deviceInfo,
        inviteCode: inviteCode,
      );

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] as String?;
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Connection error: ${e.toString()}';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await _authService.logout();
    _tokens = null;
    _user = null;
    _errorMessage = null;
    _mfaRequired = false;
    notifyListeners();
  }

  Future<bool> _refreshToken() async {
    if (_tokens == null) return false;

    try {
      final deviceInfo = await _deviceService.getDeviceInfo();
      final result = await _authService.refreshToken(
        refreshToken: _tokens!.refreshToken,
        deviceInfo: deviceInfo,
      );

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        return true;
      } else {
        // Token refresh failed, clear auth state
        await logout();
        return false;
      }
    } catch (e) {
      await logout();
      return false;
    }
  }

  Future<String?> getValidAccessToken() async {
    if (_tokens == null) return null;

    if (_tokens!.isExpired) {
      final refreshed = await _refreshToken();
      if (!refreshed) return null;
    }

    return _tokens?.accessToken;
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
