import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/auth_tokens.dart';
import '../models/user.dart';
import 'api_config.dart';
import 'log_service.dart';

class AuthService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _tokenKey = 'auth_tokens';
  static const String _userKey = 'user_data';
  static const String _apiKeyKey = 'api_key';
  static const String _authModeKey = 'auth_mode';

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    required Map<String, String> deviceInfo,
    String? otpCode,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/auth/login');

      final body = {
        'email': email,
        'password': password,
        'device': deviceInfo,
      };

      if (otpCode != null) {
        body['otp_code'] = otpCode;
      }

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));

      LogService.instance.debug('AuthService', 'Login response status: ${response.statusCode}');
      LogService.instance.debug('AuthService', 'Login response body: ${response.body}');

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        // Store tokens
        final tokens = AuthTokens.fromJson(responseData);
        await _saveTokens(tokens);

        // Store user data - parse once and reuse
        User? user;
        if (responseData['user'] != null) {
          final rawUser = responseData['user'];
          _logRawUserPayload('login', rawUser);
          user = User.fromJson(rawUser);
          await _saveUser(user);
        }

        return {
          'success': true,
          'tokens': tokens,
          'user': user,
        };
      } else if (response.statusCode == 401 && responseData['mfa_required'] == true) {
        return {
          'success': false,
          'mfa_required': true,
          'error': responseData['error'],
        };
      } else {
        return {
          'success': false,
          'error': responseData['error'] ?? responseData['errors']?.join(', ') ?? 'Login failed',
        };
      }
    } on SocketException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Login unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'An unexpected error occurred',
      };
    }
  }

  Future<Map<String, dynamic>> signup({
    required String email,
    required String password,
    required String firstName,
    required String lastName,
    required Map<String, String> deviceInfo,
    String? inviteCode,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/auth/signup');

      final Map<String, Object> body = {
        'user': {
          'email': email,
          'password': password,
          'first_name': firstName,
          'last_name': lastName,
        },
        'device': deviceInfo,
      };

      if (inviteCode != null) {
        body['invite_code'] = inviteCode;
      }

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 30));

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 201) {
        // Store tokens
        final tokens = AuthTokens.fromJson(responseData);
        await _saveTokens(tokens);

        // Store user data - parse once and reuse
        User? user;
        if (responseData['user'] != null) {
          final rawUser = responseData['user'];
          _logRawUserPayload('signup', rawUser);
          user = User.fromJson(rawUser);
          await _saveUser(user);
        }

        return {
          'success': true,
          'tokens': tokens,
          'user': user,
        };
      } else {
        return {
          'success': false,
          'error': responseData['error'] ?? responseData['errors']?.join(', ') ?? 'Signup failed',
        };
      }
    } on SocketException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'Signup unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'An unexpected error occurred',
      };
    }
  }

  Future<Map<String, dynamic>> refreshToken({
    required String refreshToken,
    required Map<String, String> deviceInfo,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/auth/refresh');

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'refresh_token': refreshToken,
          'device': deviceInfo,
        }),
      ).timeout(const Duration(seconds: 30));

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final tokens = AuthTokens.fromJson(responseData);
        await _saveTokens(tokens);

        return {
          'success': true,
          'tokens': tokens,
        };
      } else {
        return {
          'success': false,
          'error': responseData['error'] ?? 'Token refresh failed',
        };
      }
    } on SocketException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'RefreshToken unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'An unexpected error occurred',
      };
    }
  }

  Future<Map<String, dynamic>> loginWithApiKey({
    required String apiKey,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/accounts');

      final response = await http.get(
        url,
        headers: {
          'X-Api-Key': apiKey,
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      LogService.instance.debug('AuthService', 'API key login response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        await _saveApiKey(apiKey);
        return {
          'success': true,
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Invalid API key',
        };
      } else {
        return {
          'success': false,
          'error': 'Login failed (status ${response.statusCode})',
        };
      }
    } on SocketException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'API key login SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'API key login TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'API key login unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'An unexpected error occurred',
      };
    }
  }

  String buildSsoUrl({
    required String provider,
    required Map<String, String> deviceInfo,
  }) {
    final params = {
      'device_id': deviceInfo['device_id']!,
      'device_name': deviceInfo['device_name']!,
      'device_type': deviceInfo['device_type']!,
      'os_version': deviceInfo['os_version']!,
      'app_version': deviceInfo['app_version']!,
    };
    final uri = Uri.parse('${ApiConfig.baseUrl}/auth/mobile/$provider')
        .replace(queryParameters: params);
    return uri.toString();
  }

  Future<Map<String, dynamic>> handleSsoCallback(Uri uri) async {
    final params = uri.queryParameters;

    if (params.containsKey('error')) {
      return {
        'success': false,
        'error': params['message'] ?? params['error'] ?? 'SSO login failed',
      };
    }

    final code = params['code'];
    if (code == null || code.isEmpty) {
      return {
        'success': false,
        'error': 'Invalid SSO callback response',
      };
    }

    // Exchange authorization code for tokens via secure POST
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/auth/sso_exchange');
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'code': code}),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final errorData = jsonDecode(response.body);
        return {
          'success': false,
          'error': errorData['message'] ?? 'Token exchange failed',
        };
      }

      final data = jsonDecode(response.body);

      final tokens = AuthTokens.fromJson({
        'access_token': data['access_token'],
        'refresh_token': data['refresh_token'],
        'token_type': data['token_type'] ?? 'Bearer',
        'expires_in': data['expires_in'] ?? 0,
        'created_at': data['created_at'] ?? 0,
      });
      await _saveTokens(tokens);

      _logRawUserPayload('sso_exchange', data['user']);
      final user = User.fromJson(data['user']);
      await _saveUser(user);

      return {
        'success': true,
        'tokens': tokens,
        'user': user,
      };
    } on SocketException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'SSO exchange SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'SSO exchange TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } catch (e, stackTrace) {
      LogService.instance.error('AuthService', 'SSO exchange unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Failed to exchange authorization code',
      };
    }
  }

  Future<Map<String, dynamic>> enableAi({
    required String accessToken,
  }) async {
    try {
      final url = Uri.parse('${ApiConfig.baseUrl}/api/v1/auth/enable_ai');
      final response = await http.patch(
        url,
        headers: {
          ...ApiConfig.getAuthHeaders(accessToken),
          'Content-Type': 'application/json',
        },
      ).timeout(const Duration(seconds: 30));

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        _logRawUserPayload('enable_ai', responseData['user']);
        final user = User.fromJson(responseData['user']);
        await _saveUser(user);
        return {
          'success': true,
          'user': user,
        };
      }

      return {
        'success': false,
        'error': responseData['error'] ?? responseData['errors']?.join(', ') ?? 'Failed to enable AI',
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: ${e.toString()}',
      };
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
    await _storage.delete(key: _apiKeyKey);
    await _storage.delete(key: _authModeKey);
  }

  Future<AuthTokens?> getStoredTokens() async {
    final tokensJson = await _storage.read(key: _tokenKey);
    if (tokensJson == null) return null;
    
    try {
      return AuthTokens.fromJson(jsonDecode(tokensJson));
    } catch (e) {
      return null;
    }
  }

  Future<User?> getStoredUser() async {
    final userJson = await _storage.read(key: _userKey);
    if (userJson == null) return null;
    
    try {
      return User.fromJson(jsonDecode(userJson));
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveTokens(AuthTokens tokens) async {
    await _storage.write(
      key: _tokenKey,
      value: jsonEncode(tokens.toJson()),
    );
  }

  Future<void> _saveUser(User user) async {
    await _storage.write(
      key: _userKey,
      value: jsonEncode(user.toJson()),
    );
  }

  void _logRawUserPayload(String source, dynamic userPayload) {
    if (userPayload == null) {
      LogService.instance.debug('AuthService', '$source user payload: <missing>');
      return;
    }

    if (userPayload is Map<String, dynamic>) {
      try {
        LogService.instance.debug('AuthService', '$source user payload: ${jsonEncode(userPayload)}');
      } catch (_) {
        LogService.instance.debug('AuthService', '$source user payload: $userPayload');
      }
    } else {
      LogService.instance.debug('AuthService', '$source user payload type: ${userPayload.runtimeType}');
    }
  }

  Future<void> _saveApiKey(String apiKey) async {
    await _storage.write(key: _apiKeyKey, value: apiKey);
    await _storage.write(key: _authModeKey, value: 'api_key');
  }

  Future<String?> getStoredApiKey() async {
    return await _storage.read(key: _apiKeyKey);
  }

  Future<String?> getStoredAuthMode() async {
    return await _storage.read(key: _authModeKey);
  }
}
