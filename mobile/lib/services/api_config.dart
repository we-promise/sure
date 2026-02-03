import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  // Base URL for the API - can be changed to point to different environments
  // For local development, use: http://10.0.2.2:3000 (Android emulator)
  // For iOS simulator, use: http://localhost:3000
  // For production, use your actual server URL
  static String _baseUrl = 'https://app.sure.am';

  static String get baseUrl => _baseUrl;

  static void setBaseUrl(String url) {
    _baseUrl = url;
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
      return {
        'X-Api-Key': _apiKeyValue!,
        'Accept': 'application/json',
      };
    }
    return {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
  }

  /// Initialize the API configuration by loading the backend URL from storage
  /// Returns true if a saved URL was loaded, false otherwise
  static Future<bool> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString('backend_url');

      if (savedUrl != null && savedUrl.isNotEmpty) {
        _baseUrl = savedUrl;
        return true;
      }
      return false;
    } catch (e) {
      // If initialization fails, keep the default URL
      return false;
    }
  }

  // API timeout settings
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(seconds: 30);
}
