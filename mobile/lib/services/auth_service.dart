import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/auth_tokens.dart';
import '../models/user.dart';
import 'api_config.dart';

class AuthService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _tokenKey = 'auth_tokens';
  static const String _userKey = 'user_data';

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

      debugPrint('Login response status: ${response.statusCode}');
      debugPrint('Login response body: ${response.body}');

      final responseData = jsonDecode(response.body);

      if (response.statusCode == 200) {
        // Store tokens
        final tokens = AuthTokens.fromJson(responseData);
        await _saveTokens(tokens);

        // Store user data - parse once and reuse
        User? user;
        if (responseData['user'] != null) {
          user = User.fromJson(responseData['user']);
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
      debugPrint('Login SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      debugPrint('Login TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      debugPrint('Login HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      debugPrint('Login FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      debugPrint('Login TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      debugPrint('Login unexpected error: $e\n$stackTrace');
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
          user = User.fromJson(responseData['user']);
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
      debugPrint('Signup SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      debugPrint('Signup TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      debugPrint('Signup HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      debugPrint('Signup FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      debugPrint('Signup TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      debugPrint('Signup unexpected error: $e\n$stackTrace');
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
      debugPrint('RefreshToken SocketException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Network unavailable',
      };
    } on TimeoutException catch (e, stackTrace) {
      debugPrint('RefreshToken TimeoutException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Request timed out',
      };
    } on HttpException catch (e, stackTrace) {
      debugPrint('RefreshToken HttpException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on FormatException catch (e, stackTrace) {
      debugPrint('RefreshToken FormatException: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } on TypeError catch (e, stackTrace) {
      debugPrint('RefreshToken TypeError: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'Invalid response from server',
      };
    } catch (e, stackTrace) {
      debugPrint('RefreshToken unexpected error: $e\n$stackTrace');
      return {
        'success': false,
        'error': 'An unexpected error occurred',
      };
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
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
      value: jsonEncode({
        'id': user.id,
        'email': user.email,
        'first_name': user.firstName,
        'last_name': user.lastName,
      }),
    );
  }
}
