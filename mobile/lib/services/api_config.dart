import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  // Predefined environments
  static const String STAGING_ENV = 'https://companion-staging.chancen.tech';
  static const String PRODUCTION_ENV = 'https://companion.chancen.tech';

  // Base URL for the API - can be changed to point to different environments
  // For local development, use: http://10.0.2.2:3000 (Android emulator)
  // For iOS simulator, use: http://localhost:3000
  static const String _defaultBaseUrl = PRODUCTION_ENV;
  static const String _backendUrlKey = 'backend_url';
  static const String _environmentKey = 'app_environment';
  static String _baseUrl = _defaultBaseUrl;

  // Available preset environments
  static const Map<String, String> presetEnvironments = {
    'Staging': STAGING_ENV,
    'Production': PRODUCTION_ENV,
  };

  static String get baseUrl => _baseUrl;
  static String get defaultBaseUrl => _defaultBaseUrl;

  static void setBaseUrl(String url) {
    _baseUrl = url;
  }

  /// Set environment by preset name (e.g., "Staging", "Production")
  /// Returns true if successful, false if name is not found
  static Future<bool> setEnvironment(String environmentName) async {
    final url = presetEnvironments[environmentName];
    if (url == null) return false;

    try {
      final prefs = await SharedPreferences.getInstance();
      _baseUrl = url;
      await prefs.setString(_backendUrlKey, url);
      await prefs.setString(_environmentKey, environmentName);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Get the current environment name (if using preset), or 'Custom' if using custom URL
  static Future<String?> getCurrentEnvironment() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedEnv = prefs.getString(_environmentKey);
      return savedEnv;
    } catch (e) {
      return null;
    }
  }

  /// Check if current URL is a preset environment
  static bool isPresetEnvironment() {
    return presetEnvironments.containsValue(_baseUrl);
  }

  // API key authentication mode
  static bool _isApiKeyAuth = false;
  static String? _apiKeyValue;

  static bool get isApiKeyAuth => _isApiKeyAuth;

  static void setApiKeyAuth(String apiKey) {
    _isApiKeyAuth = true;
    _apiKeyValue = apiKey;
  }

  static void clearApiKeyAuth() {
    _isApiKeyAuth = false;
    _apiKeyValue = null;
  }

  /// Returns the correct auth headers based on the current auth mode.
  /// In API key mode, uses X-Api-Key header.
  /// In token mode, uses Authorization: Bearer header.
  static Map<String, String> getAuthHeaders(String token) {
    if (_isApiKeyAuth && _apiKeyValue != null) {
      return {'X-Api-Key': _apiKeyValue!, 'Accept': 'application/json'};
    }
    return {'Authorization': 'Bearer $token', 'Accept': 'application/json'};
  }

  /// Initialize the API configuration by loading the backend URL from storage
  /// Returns true when a backend URL is configured (stored or default)
  static Future<bool> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_backendUrlKey);
      final savedEnv = prefs.getString(_environmentKey);

      if (savedUrl != null && savedUrl.isNotEmpty) {
        _baseUrl = savedUrl;
        return true;
      }

      // Seed first launch with the active development backend so the app can
      // go straight to login while still letting users override it later.
      _baseUrl = _defaultBaseUrl;
      await prefs.setString(_backendUrlKey, _defaultBaseUrl);
      // Set default environment on first launch
      if (savedEnv == null) {
        await prefs.setString(_environmentKey, 'Production');
      }
      return true;
    } catch (e) {
      // If initialization fails, keep the default URL
      _baseUrl = _defaultBaseUrl;
      return true;
    }
  }

  // API timeout settings
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
}
