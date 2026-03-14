import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/user.dart';
import '../models/auth_tokens.dart';
import '../services/auth_service.dart';
import '../services/device_service.dart';
import '../services/api_config.dart';
import '../services/log_service.dart';

class AuthProvider with ChangeNotifier {
  final AuthService _authService = AuthService();
  final DeviceService _deviceService = DeviceService();

  User? _user;
  AuthTokens? _tokens;
  String? _apiKey;
  bool _isApiKeyAuth = false;
  bool _isLoading = true;
  bool _isInitializing = true; // Track initial auth check separately
  String? _errorMessage;
  bool _mfaRequired = false;
  bool _showMfaInput = false; // Track if we should show MFA input field

  // SSO onboarding state
  bool _ssoOnboardingPending = false;
  String? _ssoLinkingCode;
  String? _ssoEmail;
  String? _ssoFirstName;
  String? _ssoLastName;
  bool _ssoAllowAccountCreation = false;
  bool _ssoHasPendingInvitation = false;

  User? get user => _user;
  bool get isIntroLayout => _user?.isIntroLayout ?? false;
  bool get aiEnabled => _user?.aiEnabled ?? false;
  AuthTokens? get tokens => _tokens;
  bool get isLoading => _isLoading;
  bool get isInitializing => _isInitializing; // Expose initialization state
  bool get isApiKeyAuth => _isApiKeyAuth;
  bool get isAuthenticated =>
      (_isApiKeyAuth && _apiKey != null) ||
      (_tokens != null && !_tokens!.isExpired);
  String? get errorMessage => _errorMessage;
  bool get mfaRequired => _mfaRequired;
  bool get showMfaInput => _showMfaInput; // Expose MFA input state

  // SSO onboarding getters
  bool get ssoOnboardingPending => _ssoOnboardingPending;
  String? get ssoLinkingCode => _ssoLinkingCode;
  String? get ssoEmail => _ssoEmail;
  String? get ssoFirstName => _ssoFirstName;
  String? get ssoLastName => _ssoLastName;
  bool get ssoAllowAccountCreation => _ssoAllowAccountCreation;
  bool get ssoHasPendingInvitation => _ssoHasPendingInvitation;

  AuthProvider() {
    _loadStoredAuth();
  }

  Future<void> _loadStoredAuth() async {
    _isLoading = true;
    _isInitializing = true;
    notifyListeners();

    try {
      final authMode = await _authService.getStoredAuthMode();

      if (authMode == 'api_key') {
        _apiKey = await _authService.getStoredApiKey();
        if (_apiKey != null) {
          _isApiKeyAuth = true;
          ApiConfig.setApiKeyAuth(_apiKey!);
        }
      } else {
        _tokens = await _authService.getStoredTokens();
        _user = await _authService.getStoredUser();

        // If tokens exist but are expired, try to refresh only when online
        if (_tokens != null && _tokens!.isExpired) {
          final results = await Connectivity().checkConnectivity();
          final isOnline = results.any((r) =>
              r == ConnectivityResult.mobile ||
              r == ConnectivityResult.wifi ||
              r == ConnectivityResult.ethernet ||
              r == ConnectivityResult.vpn ||
              r == ConnectivityResult.bluetooth);
          if (isOnline) {
            await _refreshToken();
          } else {
            await logout();
          }
        }
      }
    } catch (e) {
      _tokens = null;
      _user = null;
      _apiKey = null;
      _isApiKeyAuth = false;
    }

    _isLoading = false;
    _isInitializing = false;
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
    // Don't reset _showMfaInput if we're submitting OTP code
    if (otpCode == null) {
      _showMfaInput = false;
    }
    notifyListeners();

    try {
      final deviceInfo = await _deviceService.getDeviceInfo();
      final result = await _authService.login(
        email: email,
        password: password,
        deviceInfo: deviceInfo,
        otpCode: otpCode,
      );

      LogService.instance.debug('AuthProvider', 'Login result: $result');

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _mfaRequired = false;
        _showMfaInput = false; // Reset on successful login
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        if (result['mfa_required'] == true) {
          _mfaRequired = true;
          _showMfaInput = true; // Show MFA input field
          LogService.instance.debug('AuthProvider', 'MFA required! Setting _showMfaInput to true');

          // If user already submitted an OTP code, this is likely an invalid OTP error
          // Show the error message so user knows the code was wrong
          if (otpCode != null && otpCode.isNotEmpty) {
            // Backend returns "Two-factor authentication required" for both cases
            // Replace with clearer message when OTP was actually submitted
            _errorMessage = 'Invalid authentication code. Please try again.';
          } else {
            // First time requesting MFA - don't show error message, it's a normal flow
            _errorMessage = null;
          }
        } else {
          _errorMessage = result['error'] as String?;
          // If user submitted an OTP (is in MFA flow) but got error, keep MFA input visible
          if (otpCode != null) {
            _showMfaInput = true;
          }
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

  Future<bool> loginWithApiKey({
    required String apiKey,
  }) async {
    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final result = await _authService.loginWithApiKey(apiKey: apiKey);

      LogService.instance.debug('AuthProvider', 'API key login result: $result');

      if (result['success'] == true) {
        _apiKey = apiKey;
        _isApiKeyAuth = true;
        ApiConfig.setApiKeyAuth(apiKey);
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] as String?;
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e, stackTrace) {
      LogService.instance.error('AuthProvider', 'API key login error: $e\n$stackTrace');
      _errorMessage = 'Unable to connect. Please check your network and try again.';
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

  Future<void> startSsoLogin(String provider) async {
    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final deviceInfo = await _deviceService.getDeviceInfo();
      final ssoUrl = _authService.buildSsoUrl(
        provider: provider,
        deviceInfo: deviceInfo,
      );

      final launched = await launchUrl(Uri.parse(ssoUrl), mode: LaunchMode.externalApplication);
      if (!launched) {
        _errorMessage = 'Unable to open browser for sign-in.';
      }
    } catch (e, stackTrace) {
      LogService.instance.error('AuthProvider', 'SSO launch error: $e\n$stackTrace');
      _errorMessage = 'Unable to start sign-in. Please try again.';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<bool> handleSsoCallback(Uri uri) async {
    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final result = await _authService.handleSsoCallback(uri);

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _ssoOnboardingPending = false;
        _isLoading = false;
        notifyListeners();
        return true;
      } else if (result['account_not_linked'] == true) {
        // SSO onboarding needed - store linking data
        _ssoOnboardingPending = true;
        _ssoLinkingCode = result['linking_code'] as String?;
        _ssoEmail = result['email'] as String?;
        _ssoFirstName = result['first_name'] as String?;
        _ssoLastName = result['last_name'] as String?;
        _ssoAllowAccountCreation = result['allow_account_creation'] == true;
        _ssoHasPendingInvitation = result['has_pending_invitation'] == true;
        _isLoading = false;
        notifyListeners();
        return false;
      } else {
        _errorMessage = result['error'] as String?;
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e, stackTrace) {
      LogService.instance.error('AuthProvider', 'SSO callback error: $e\n$stackTrace');
      _errorMessage = 'Sign-in failed. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> ssoLinkAccount({
    required String email,
    required String password,
  }) async {
    if (_ssoLinkingCode == null) {
      _errorMessage = 'No pending SSO session. Please try signing in again.';
      notifyListeners();
      return false;
    }

    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final result = await _authService.ssoLink(
        linkingCode: _ssoLinkingCode!,
        email: email,
        password: password,
      );

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _clearSsoOnboardingState();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] as String?;
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e, stackTrace) {
      LogService.instance.error('AuthProvider', 'SSO link error: $e\n$stackTrace');
      _errorMessage = 'Failed to link account. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> ssoCreateAccount({
    String? firstName,
    String? lastName,
  }) async {
    if (_ssoLinkingCode == null) {
      _errorMessage = 'No pending SSO session. Please try signing in again.';
      notifyListeners();
      return false;
    }

    _errorMessage = null;
    _isLoading = true;
    notifyListeners();

    try {
      final result = await _authService.ssoCreateAccount(
        linkingCode: _ssoLinkingCode!,
        firstName: firstName,
        lastName: lastName,
      );

      if (result['success'] == true) {
        _tokens = result['tokens'] as AuthTokens?;
        _user = result['user'] as User?;
        _clearSsoOnboardingState();
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _errorMessage = result['error'] as String?;
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } catch (e, stackTrace) {
      LogService.instance.error('AuthProvider', 'SSO create account error: $e\n$stackTrace');
      _errorMessage = 'Failed to create account. Please try again.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void cancelSsoOnboarding() {
    _clearSsoOnboardingState();
    notifyListeners();
  }

  void _clearSsoOnboardingState() {
    _ssoOnboardingPending = false;
    _ssoLinkingCode = null;
    _ssoEmail = null;
    _ssoFirstName = null;
    _ssoLastName = null;
    _ssoAllowAccountCreation = false;
    _ssoHasPendingInvitation = false;
  }

  Future<void> logout() async {
    await _authService.logout();
    _tokens = null;
    _user = null;
    _apiKey = null;
    _isApiKeyAuth = false;
    _errorMessage = null;
    _mfaRequired = false;
    ApiConfig.clearApiKeyAuth();
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
    if (_isApiKeyAuth && _apiKey != null) {
      return _apiKey;
    }

    if (_tokens == null) return null;

    if (_tokens!.isExpired) {
      final refreshed = await _refreshToken();
      if (!refreshed) return null;
    }

    return _tokens?.accessToken;
  }

  Future<bool> enableAi() async {
    final accessToken = await getValidAccessToken();
    if (accessToken == null) {
      _errorMessage = 'Session expired. Please login again.';
      notifyListeners();
      return false;
    }

    final result = await _authService.enableAi(accessToken: accessToken);
    if (result['success'] == true) {
      _user = result['user'] as User?;
      _errorMessage = null;
      notifyListeners();
      return true;
    }

    _errorMessage = result['error'] as String?;
    notifyListeners();
    return false;
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
