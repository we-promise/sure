import 'package:shared_preferences/shared_preferences.dart';

import '../models/custom_proxy_header.dart';
import 'custom_proxy_headers_service.dart';

class ApiConfig {
  // Base URL for the API - can be changed to point to different environments
  // For local development, use: http://10.0.2.2:3000 (Android emulator)
  // For iOS simulator, use: http://localhost:3000
  // For production, use your actual server URL
  static const String _defaultBaseUrl = 'https://demo.sure.am';
  static const String _backendUrlKey = 'backend_url';
  static String _baseUrl = _defaultBaseUrl;

  static String get baseUrl => _baseUrl;
  static String get defaultBaseUrl => _defaultBaseUrl;

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

  // Custom proxy headers
  static List<CustomProxyHeader> _customProxyHeaders = [];

  static List<CustomProxyHeader> get customProxyHeaders =>
      List.unmodifiable(_customProxyHeaders);

  static void setCustomProxyHeaders(List<CustomProxyHeader> headers) {
    _customProxyHeaders = CustomProxyHeader.sanitize(headers);
  }

  static Map<String, String> get customProxyHeaderMap {
    return {
      for (final header in _customProxyHeaders) header.name: header.value,
    };
  }

  static Map<String, String> jsonHeaders() {
    return {
      ...customProxyHeaderMap,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
  }

  static Map<String, String> htmlHeaders() {
    return {
      ...customProxyHeaderMap,
      'Accept': 'text/html',
    };
  }

  /// Returns the correct auth headers based on the current auth mode.
  /// In API key mode, uses X-Api-Key header.
  /// In token mode, uses Authorization: Bearer header.
  static Map<String, String> getAuthHeaders(String token) {
    if (_isApiKeyAuth && _apiKeyValue != null) {
      return {
        ...customProxyHeaderMap,
        'X-Api-Key': _apiKeyValue!,
        'Accept': 'application/json',
      };
    }
    return {
      ...customProxyHeaderMap,
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
  }

  /// Initialize the API configuration by loading the backend URL from storage
  /// Returns true when a backend URL is configured (stored or default)
  static Future<bool> initialize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedUrl = prefs.getString(_backendUrlKey);

      if (savedUrl != null && savedUrl.isNotEmpty) {
        _baseUrl = savedUrl;
        _customProxyHeaders = await CustomProxyHeadersService.instance.loadHeaders();
        return true;
      }

      // Seed first launch with the active development backend so the app can
      // go straight to login while still letting users override it later.
      _baseUrl = _defaultBaseUrl;
      await prefs.setString(_backendUrlKey, _defaultBaseUrl);
      _customProxyHeaders = await CustomProxyHeadersService.instance.loadHeaders();
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
