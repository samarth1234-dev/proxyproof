import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String defaultUrl = 'http://172.17.176.112:5050';
  
  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_base_url') ?? defaultUrl;
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url.trim());
  }

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('auth_token');
  }

  Future<Map<String, dynamic>?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('current_user');
    if (jsonStr == null) return null;
    try {
      return jsonDecode(jsonStr);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveAuthData({
    required String token,
    required String role,
    required int userId,
    required String username,
    String? fullName,
    String? deviceId,
    bool isApproved = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_token', token);
    await prefs.setString('user_role', role);
    await prefs.setInt('user_id', userId);
    await prefs.setString('username', username);
    final userMap = {
      'id': userId,
      'username': username,
      'fullName': fullName ?? username,
      'role': role,
      'deviceId': deviceId,
      'isApproved': isApproved,
    };
    await prefs.setString('current_user', jsonEncode(userMap));
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_role');
    await prefs.remove('user_id');
    await prefs.remove('username');
    await prefs.remove('current_user');
  }

  Future<Map<String, String>> _headers({bool needsAuth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (needsAuth) {
      final token = await getToken();
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  // Smart fallback connection engine: automatically tests configured IP, Wi-Fi IP, Emulator 10.0.2.2, and localhost
  Future<http.Response> _sendWithFallback(
    String path,
    String method, {
    Map<String, String>? headers,
    dynamic body,
  }) async {
    final configured = await getBaseUrl();
    final candidates = [
      'http://127.0.0.1:5050',
      'http://localhost:5050',
      configured,
      'http://172.17.176.112:5050',
      'http://10.0.2.2:5050',
    ].toSet().toList();

    for (final base in candidates) {
      try {
        final uri = Uri.parse('$base$path');
        http.Response res;
        if (method == 'POST') {
          res = await http.post(uri, headers: headers, body: body).timeout(const Duration(milliseconds: 2500));
        } else if (method == 'PUT') {
          res = await http.put(uri, headers: headers, body: body).timeout(const Duration(milliseconds: 2500));
        } else {
          res = await http.get(uri, headers: headers).timeout(const Duration(milliseconds: 2500));
        }
        if (base != configured) {
          await setBaseUrl(base);
          debugPrint('Connected via fallback address: $base');
        }
        return res;
      } catch (_) {
        // try next candidate
      }
    }
    throw Exception('Failed to connect to backend on any address. Please ensure server is running.');
  }

  // --- AUTHENTICATION ---
  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String fullName,
    required String role,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/auth/register',
        'POST',
        headers: await _headers(needsAuth: false),
        body: jsonEncode({
          'username': username,
          'password': password,
          'fullName': fullName,
          'role': role,
        }),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': 'Could not connect to server ($e)'};
    }
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/auth/login',
        'POST',
        headers: await _headers(needsAuth: false),
        body: jsonEncode({'username': username, 'password': password}),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['token'] != null) {
        await saveAuthData(
          token: data['token'],
          role: data['role'],
          userId: data['userId'],
          username: data['username'],
          fullName: data['fullName'],
          deviceId: data['deviceId'],
          isApproved: data['isApproved'] ?? true,
        );
      }
      return data;
    } catch (e) {
      return {'error': 'Network connection failed: $e'};
    }
  }

  Future<Map<String, dynamic>> getMe() async {
    try {
      final response = await _sendWithFallback(
        '/auth/me',
        'GET',
        headers: await _headers(),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // --- DEVICE BINDING ---
  Future<Map<String, dynamic>> bindDevice({
    required String deviceId,
    String? deviceModel,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/user/bind-device',
        'PUT',
        headers: await _headers(),
        body: jsonEncode({'deviceId': deviceId, 'deviceModel': deviceModel ?? 'Mobile Device'}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<List<dynamic>> getPendingApprovals() async {
    try {
      final response = await _sendWithFallback(
        '/admin/pending-approvals',
        'GET',
        headers: await _headers(),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> approveDevice({
    required int userId,
    required bool approve,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/admin/approve-device',
        'PUT',
        headers: await _headers(),
        body: jsonEncode({'userId': userId, 'approve': approve}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  // --- SESSION MANAGEMENT ---
  Future<Map<String, dynamic>> startSession({
    required String title,
    int durationMinutes = 5,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/session/start',
        'POST',
        headers: await _headers(),
        body: jsonEncode({'title': title, 'durationMinutes': durationMinutes}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> rotateToken({
    required int sessionId,
    String? newToken,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/session/rotate-token',
        'PUT',
        headers: await _headers(),
        body: jsonEncode({'sessionId': sessionId, 'newToken': newToken}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> closeSession(int sessionId) async {
    try {
      final response = await _sendWithFallback(
        '/session/close',
        'POST',
        headers: await _headers(),
        body: jsonEncode({'sessionId': sessionId}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> getActiveSession() async {
    try {
      final response = await _sendWithFallback(
        '/session/active',
        'GET',
        headers: await _headers(needsAuth: false),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'active': false, 'error': e.toString()};
    }
  }

  // --- ATTENDANCE MARKING ---
  Future<Map<String, dynamic>> markAttendance({
    required int sessionId,
    required String token,
    required int rssi,
    required String deviceId,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/attendance/mark',
        'POST',
        headers: await _headers(),
        body: jsonEncode({
          'sessionId': sessionId,
          'token': token,
          'rssi': rssi,
          'deviceId': deviceId,
        }),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': 'Failed to reach server: $e'};
    }
  }

  Future<List<dynamic>> getDashboard(int sessionId) async {
    try {
      final response = await _sendWithFallback(
        '/attendance/dashboard/$sessionId',
        'GET',
        headers: await _headers(),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> manualAdd({
    required int sessionId,
    required String username,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/attendance/manual-add',
        'POST',
        headers: await _headers(),
        body: jsonEncode({'sessionId': sessionId, 'username': username}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> manualRemove({
    required int sessionId,
    required int studentId,
  }) async {
    try {
      final response = await _sendWithFallback(
        '/attendance/manual-remove',
        'POST',
        headers: await _headers(),
        body: jsonEncode({'sessionId': sessionId, 'studentId': studentId}),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> getHistory() async {
    try {
      final response = await _sendWithFallback(
        '/attendance/history',
        'GET',
        headers: await _headers(),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {'error': e.toString()};
    }
  }

  Future<String> getExportUrl(int sessionId) async {
    final baseUrl = await getBaseUrl();
    return '$baseUrl/attendance/export/$sessionId';
  }

  Future<List<dynamic>> getAllStudents() async {
    try {
      final response = await _sendWithFallback(
        '/students',
        'GET',
        headers: await _headers(needsAuth: false),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return [];
    }
  }
}
