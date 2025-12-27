import 'package:shared_preferences/shared_preferences.dart';

class ApiConfig {
  // Base URL for the API - can be changed to point to different environments
  // For local development, use: http://10.0.2.2:3000 (Android emulator)
  // For iOS simulator, use: http://localhost:3000
  // For production, use your actual server URL
  static String _baseUrl = 'http://10.0.2.2:3000';

  static String get baseUrl => _baseUrl;

  static void setBaseUrl(String url) {
    _baseUrl = url;
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
