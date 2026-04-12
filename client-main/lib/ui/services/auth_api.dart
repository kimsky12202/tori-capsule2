import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AuthApiException implements Exception {
  const AuthApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LoginResult {
  const LoginResult({
    required this.accessToken,
    required this.userId,
    required this.email,
    required this.username,
  });

  final String accessToken;
  final String userId;
  final String email;
  final String username;
}

class AuthApi {
  AuthApi({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  static final String _baseUrl = _resolveBaseUrl();

  final http.Client _httpClient;

  static String _resolveBaseUrl() {
    const configuredBaseUrl = String.fromEnvironment('API_BASE_URL');
    if (configuredBaseUrl.isNotEmpty) {
      return configuredBaseUrl;
    }

    if (kIsWeb) {
      return 'http://118.34.15.14:8090';
    }

    if (Platform.isAndroid) {
      return 'http://118.34.15.14:8090';
    }

    return 'http://118.34.15.14:8090';
  }

  Future<void> register({
    required String email,
    required String username,
    required String password,
    required String passwordConfirm,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/users'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'username': username,
        'password': password,
        'passwordConfirm': passwordConfirm,
      }),
    );

    if (response.statusCode == 201) {
      return;
    }

    throw AuthApiException(_extractErrorMessage(response));
  }

  Future<void> requestVerification({required String email}) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/users/request-verification'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email}),
    );

    if (response.statusCode == 200) {
      return;
    }

    throw AuthApiException(_extractErrorMessage(response));
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final response = await _httpClient.post(
      Uri.parse('$_baseUrl/users/login'),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (response.statusCode != 200) {
      throw AuthApiException(_extractErrorMessage(response));
    }

    final dynamic data = jsonDecode(response.body);
    if (data is! Map<String, dynamic>) {
      throw const AuthApiException('invalid response from server');
    }

    final dynamic tokenData = data['token'];
    final dynamic userData = data['user'];

    if (tokenData is! Map<String, dynamic> ||
        userData is! Map<String, dynamic>) {
      throw const AuthApiException('invalid response from server');
    }

    return LoginResult(
      accessToken: (tokenData['access_token'] ?? '').toString(),
      userId: (userData['id'] ?? '').toString(),
      email: (userData['email'] ?? '').toString(),
      username: (userData['username'] ?? userData['name'] ?? '').toString(),
    );
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final dynamic body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['message'] != null) {
        return body['message'].toString();
      }
    } catch (_) {
      // Falls back to a generic message when response body is not JSON.
    }

    return 'request failed: ${response.statusCode}';
  }
}
