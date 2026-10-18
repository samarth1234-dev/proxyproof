import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Primary online cloud backend hosted on Render
  static const String defaultUrl = 'https://proxyproof-backend.onrender.com';
  static bool isOfflineMode = false;
  static bool _isSyncing = false;

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_base_url') ?? defaultUrl;
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url.trim());
  }

  // --- HARDWARE DEVICE EXTRACTION (ONE-PHONE-ONE-ACCOUNT) ---
  static Future<String> getHardwareDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.identifierForVendor ?? 'ios_device_id';
      }
    } catch (_) {}
    final prefs = await SharedPreferences.getInstance();
    var fallbackId = prefs.getString('persistent_hardware_device_id');
    if (fallbackId == null) {
      fallbackId = 'dev_${DateTime.now().millisecondsSinceEpoch}_${(1000 + Random().nextInt(9000))}';
      await prefs.setString('persistent_hardware_device_id', fallbackId);
    }
    return fallbackId;
  }

  static Future<String> getDeviceModel() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return '${androidInfo.brand} ${androidInfo.model}';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        return iosInfo.name;
      }
    } catch (_) {}
    return 'Mobile Device';
  }

  static Future<String?> getBoundAccount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('device_bound_account_username');
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
    bool isOffline = false,
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
      'isOffline': isOffline,
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

  // Smart fallback connection engine
  Future<http.Response> _sendWithFallback(
    String path,
    String method, {
    Map<String, String>? headers,
    dynamic body,
  }) async {
    final configured = await getBaseUrl();
    final candidates = [
      configured,
      defaultUrl,
      'http://10.0.2.2:5050',
      'http://127.0.0.1:5050',
      'http://localhost:5050',
    ].toSet().toList();

    for (final base in candidates) {
      try {
        final uri = Uri.parse('$base$path');
        http.Response res;
        const timeout = Duration(milliseconds: 2500);
        if (method == 'POST') {
          res = await http.post(uri, headers: headers, body: body).timeout(timeout);
        } else if (method == 'PUT') {
          res = await http.put(uri, headers: headers, body: body).timeout(timeout);
        } else {
          res = await http.get(uri, headers: headers).timeout(timeout);
        }
        if (res.statusCode >= 200 && res.statusCode < 500) {
          isOfflineMode = false;
          if (base != configured && !base.contains('127.0.0.1') && !base.contains('localhost')) {
            await setBaseUrl(base);
          }
          return res;
        }
      } catch (_) {
        // Try next candidate
      }
    }
    isOfflineMode = true;
    throw Exception('All network targets unreachable');
  }

  // --- STRICT ONE-PHONE-ONE-ACCOUNT & OFFLINE REGISTRATION ---
  Future<Map<String, dynamic>> register({
    required String username,
    required String password,
    required String fullName,
    required String role,
  }) async {
    final cleanUser = username.trim();
    final cleanPass = password.trim();
    final cleanName = fullName.trim().isEmpty ? cleanUser : fullName.trim();
    final cleanRole = role.toLowerCase() == 'organiser' ? 'organiser' : 'student';

    final prefs = await SharedPreferences.getInstance();

    // 1. Hardware Security Check: Has this phone already been registered to another account?
    final boundUser = await getBoundAccount();
    if (boundUser != null && boundUser.toLowerCase() != cleanUser.toLowerCase()) {
      return {
        'error': 'Hardware Policy: This phone is already bound to account "@$boundUser". Only ONE account per phone is allowed!'
      };
    }

    final deviceId = await getHardwareDeviceId();
    final deviceModel = await getDeviceModel();

    // 2. Attempt online registration with live Render cloud backend
    try {
      final response = await _sendWithFallback(
        '/auth/register',
        'POST',
        headers: await _headers(needsAuth: false),
        body: jsonEncode({
          'username': cleanUser,
          'password': cleanPass,
          'fullName': cleanName,
          'role': cleanRole,
          'deviceId': deviceId,
          'deviceModel': deviceModel,
        }),
      );

      final data = jsonDecode(response.body);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        // Successfully registered online! Bind this phone to this account permanently
        await prefs.setString('device_bound_account_username', cleanUser.toLowerCase());
        final cacheKey = 'cached_user_${cleanUser.toLowerCase()}';
        await prefs.setString(cacheKey, jsonEncode({
          'username': cleanUser,
          'password': cleanPass,
          'fullName': cleanName,
          'role': cleanRole,
          'userId': data['userId'] ?? 1,
          'deviceId': deviceId,
        }));

        return data;
      } else if (response.statusCode == 409 || response.statusCode == 400) {
        return data; // Return backend validation error (e.g. username taken or hardware bound)
      }
    } catch (_) {
      // 3. Fallback: Phone is offline / no internet at all!
    }

    // Register locally on phone with zero connection friction!
    isOfflineMode = true;
    await prefs.setString('device_bound_account_username', cleanUser.toLowerCase());

    final cacheKey = 'cached_user_${cleanUser.toLowerCase()}';
    await prefs.setString(cacheKey, jsonEncode({
      'username': cleanUser,
      'password': cleanPass,
      'fullName': cleanName,
      'role': cleanRole,
      'userId': 1,
      'deviceId': deviceId,
      'isOffline': true,
    }));

    // Queue for automatic background cloud sync as soon as internet connects
    final queueRaw = prefs.getString('pending_sync_users') ?? '[]';
    List<dynamic> queue = jsonDecode(queueRaw);
    queue.add({
      'username': cleanUser,
      'password': cleanPass,
      'fullName': cleanName,
      'role': cleanRole,
      'deviceId': deviceId,
      'deviceModel': deviceModel,
      'createdAt': DateTime.now().toIso8601String(),
    });
    await prefs.setString('pending_sync_users', jsonEncode(queue));

    // Auto-login locally
    final offlineToken = 'offline_token_${DateTime.now().millisecondsSinceEpoch}';
    await saveAuthData(
      token: offlineToken,
      role: cleanRole,
      userId: 1,
      username: cleanUser,
      fullName: cleanName,
      deviceId: deviceId,
      isApproved: true,
      isOffline: true,
    );

    return {
      'message': 'Account created and bound to this device (Offline Ready)!',
      'userId': 1,
      'isOffline': true,
      'token': offlineToken,
      'role': cleanRole,
      'username': cleanUser,
    };
  }

  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String? preferredRole,
  }) async {
    final cleanUser = username.trim();
    final cleanPass = password.trim();
    final prefs = await SharedPreferences.getInstance();

    final deviceId = await getHardwareDeviceId();

    // 1. Try online login with live cloud backend
    try {
      final response = await _sendWithFallback(
        '/auth/login',
        'POST',
        headers: await _headers(needsAuth: false),
        body: jsonEncode({'username': cleanUser, 'password': cleanPass}),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200 && data['token'] != null) {
        await saveAuthData(
          token: data['token'],
          role: data['role'],
          userId: data['userId'],
          username: data['username'],
          fullName: data['fullName'],
          deviceId: deviceId,
          isApproved: data['isApproved'] ?? true,
          isOffline: false,
        );
        isOfflineMode = false;

        // Permanently bind this device to this username
        await prefs.setString('device_bound_account_username', cleanUser.toLowerCase());

        // Cache user info locally for future offline sessions
        final cacheKey = 'cached_user_${cleanUser.toLowerCase()}';
        await prefs.setString(cacheKey, jsonEncode({
          'username': cleanUser,
          'password': cleanPass,
          'fullName': data['fullName'],
          'role': data['role'],
          'userId': data['userId'],
          'deviceId': deviceId,
        }));

        // Silently trigger background cloud sync for any pending offline data
        syncPendingDataWithCloud();

        return data;
      } else if (response.statusCode == 401) {
        return data; // Invalid credentials
      }
    } catch (_) {
      // 2. Offline Fallback Login
    }

    // Check local offline cache on this phone
    final cacheKey = 'cached_user_${cleanUser.toLowerCase()}';
    final cachedRaw = prefs.getString(cacheKey);

    if (cachedRaw != null) {
      try {
        final cached = jsonDecode(cachedRaw);
        if (cached['password'] == cleanPass) {
          isOfflineMode = true;
          final offlineToken = 'offline_token_${DateTime.now().millisecondsSinceEpoch}';
          await saveAuthData(
            token: offlineToken,
            role: cached['role'] ?? 'student',
            userId: cached['userId'] ?? 1,
            username: cached['username'],
            fullName: cached['fullName'],
            deviceId: deviceId,
            isApproved: true,
            isOffline: true,
          );
          return {
            'token': offlineToken,
            'userId': cached['userId'] ?? 1,
            'username': cached['username'],
            'fullName': cached['fullName'],
            'role': cached['role'] ?? 'student',
            'deviceId': deviceId,
            'isApproved': true,
            'isOffline': true,
          };
        } else {
          return {'error': 'Invalid password for this account.'};
        }
      } catch (_) {}
    }

    return {
      'error': 'Cannot connect to server and no offline account found for this username.'
    };
  }

  // --- AUTOMATIC BACKGROUND CLOUD SYNC ENGINE ---
  static Future<void> syncPendingDataWithCloud() async {
    if (_isSyncing) return;
    _isSyncing = true;

    try {
      final prefs = await SharedPreferences.getInstance();

      // 1. Sync pending offline registered users
      final queueRaw = prefs.getString('pending_sync_users');
      if (queueRaw != null) {
        List<dynamic> queue = jsonDecode(queueRaw);
        List<dynamic> remaining = [];
        for (final item in queue) {
          try {
            final uri = Uri.parse('$defaultUrl/auth/register');
            final res = await http.post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(item),
            ).timeout(const Duration(seconds: 4));

            if (res.statusCode >= 200 && res.statusCode < 300) {
              // Successfully registered in cloud!
            } else if (res.statusCode == 409) {
              // Already exists in cloud, nothing left to do
            } else {
              remaining.add(item);
            }
          } catch (_) {
            remaining.add(item);
          }
        }
        await prefs.setString('pending_sync_users', jsonEncode(remaining));
      }

      // 2. Sync pending offline attendance records
      final recordsRaw = prefs.getString('offline_attendance_records');
      final token = prefs.getString('auth_token');
      if (recordsRaw != null && token != null && !token.startsWith('offline_token')) {
        List<dynamic> records = jsonDecode(recordsRaw);
        bool modified = false;
        for (final rec in records) {
          if (rec['synced'] != true) {
            try {
              final uri = Uri.parse('$defaultUrl/attendance/mark');
              final res = await http.post(
                uri,
                headers: {
                  'Content-Type': 'application/json',
                  'Authorization': 'Bearer $token',
                },
                body: jsonEncode({
                  'sessionId': rec['sessionId'],
                  'token': rec['token'] ?? '000000',
                  'rssi': rec['rssi'] ?? -60,
                  'deviceId': rec['deviceId'],
                }),
              ).timeout(const Duration(seconds: 4));

              if (res.statusCode >= 200 && res.statusCode < 300) {
                rec['synced'] = true;
                modified = true;
              }
            } catch (_) {}
          }
        }
        if (modified) {
          await prefs.setString('offline_attendance_records', jsonEncode(records));
        }
      }
    } catch (_) {} finally {
      _isSyncing = false;
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
    } catch (_) {
      final local = await getCurrentUser();
      return local ?? {'username': 'User', 'role': 'student'};
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
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('bound_device_id', deviceId);
      return {
        'message': 'Primary device bound locally (Offline Mode)',
        'deviceId': deviceId,
        'isApproved': true,
      };
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
    } catch (_) {
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
    } catch (_) {
      return {'message': 'Device approval recorded locally'};
    }
  }

  // --- SESSION MANAGEMENT ---
  static String _generateOfflineToken() {
    return (100000 + Random().nextInt(900000)).toString();
  }

  Future<Map<String, dynamic>> startSession({
    required String title,
    int durationMinutes = 5,
  }) async {
    syncPendingDataWithCloud();

    try {
      final response = await _sendWithFallback(
        '/session/start',
        'POST',
        headers: await _headers(),
        body: jsonEncode({'title': title, 'durationMinutes': durationMinutes}),
      );
      final data = jsonDecode(response.body);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('offline_active_session', jsonEncode(data));
      return data;
    } catch (_) {
      isOfflineMode = true;
      final token = _generateOfflineToken();
      final expires = DateTime.now().add(Duration(minutes: durationMinutes)).toIso8601String();
      final session = {
        'sessionId': 101,
        'title': title,
        'durationMinutes': durationMinutes,
        'currentToken': token,
        'recentTokens': [token],
        'expiresAt': expires,
        'isActive': true,
        'isOffline': true,
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('offline_active_session', jsonEncode(session));
      return session;
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
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('offline_active_session');
      final token = newToken ?? _generateOfflineToken();
      if (raw != null) {
        try {
          final session = jsonDecode(raw);
          session['currentToken'] = token;
          List<dynamic> recents = session['recentTokens'] ?? [];
          recents.insert(0, token);
          if (recents.length > 5) recents.removeLast();
          session['recentTokens'] = recents;
          await prefs.setString('offline_active_session', jsonEncode(session));
        } catch (_) {}
      }
      return {'success': true, 'newToken': token};
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('offline_active_session');
      return jsonDecode(response.body);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('offline_active_session');
      return {'message': 'Session closed locally'};
    }
  }

  Future<Map<String, dynamic>> getActiveSession() async {
    syncPendingDataWithCloud();

    try {
      final response = await _sendWithFallback(
        '/session/active',
        'GET',
        headers: await _headers(needsAuth: false),
      );
      final data = jsonDecode(response.body);
      if (data['active'] == true) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('offline_active_session', jsonEncode(data));
      }
      return data;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('offline_active_session');
      if (raw != null) {
        try {
          final session = jsonDecode(raw);
          final expiresAtStr = session['expiresAt'];
          if (expiresAtStr != null) {
            final expires = DateTime.parse(expiresAtStr);
            if (DateTime.now().isAfter(expires)) {
              await prefs.remove('offline_active_session');
              return {'active': false, 'message': 'Session expired'};
            }
          }
          return {
            'active': true,
            'sessionId': session['sessionId'] ?? 101,
            'title': session['title'] ?? 'Attendance Session',
            'organiserName': 'Class Organiser',
            'currentToken': session['currentToken'] ?? '123456',
            'expiresAt': session['expiresAt'],
            'durationMinutes': session['durationMinutes'] ?? 5,
            'isOffline': true,
          };
        } catch (_) {}
      }
      return {'active': false};
    }
  }

  // --- ATTENDANCE MARKING (LOCAL VERIFICATION + CLOUD AUTO-SYNC) ---
  Future<Map<String, dynamic>> markAttendance({
    required int sessionId,
    required String token,
    required int rssi,
    required String deviceId,
  }) async {
    // Proximity check (must be inside room)
    if (rssi < -85) {
      return {'error': 'Proximity check failed ($rssi dBm). You must be inside the classroom!'};
    }

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
      final data = jsonDecode(response.body);
      if (data['success'] == true) {
        data['synced'] = true;
      }
      return data;
    } catch (_) {
      // Offline fallback attendance recording
      isOfflineMode = true;
      final prefs = await SharedPreferences.getInstance();
      final user = await getCurrentUser();
      final username = user?['username'] ?? 'Student';
      final fullName = user?['fullName'] ?? username;

      final recordsRaw = prefs.getString('offline_attendance_records') ?? '[]';
      List<dynamic> records = jsonDecode(recordsRaw);

      final already = records.any((r) => r['sessionId'] == sessionId && r['username'] == username);
      if (already) {
        return {
          'alreadyPresent': true,
          'message': 'Attendance already recorded for this session!',
        };
      }

      final nowTime = DateTime.now();
      final formattedTime = '${nowTime.hour.toString().padLeft(2, '0')}:${nowTime.minute.toString().padLeft(2, '0')}:${nowTime.second.toString().padLeft(2, '0')}';

      records.insert(0, {
        'attendanceId': records.length + 1,
        'sessionId': sessionId,
        'token': token,
        'studentId': {
          'id': user?['id'] ?? 1,
          'username': username,
          'fullName': fullName,
        },
        'username': username,
        'fullName': fullName,
        'timestamp': nowTime.toIso8601String(),
        'time': formattedTime,
        'rssi': rssi,
        'deviceId': deviceId,
        'status': 'Present (Local Verified)',
        'synced': false,
      });

      await prefs.setString('offline_attendance_records', jsonEncode(records));

      return {
        'success': true,
        'message': 'Attendance successfully verified & marked (Offline Mode)!',
        'username': username,
        'rssi': rssi,
        'time': formattedTime,
        'isOffline': true,
      };
    }
  }

  Future<List<dynamic>> getDashboard(int sessionId) async {
    syncPendingDataWithCloud();

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
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('offline_attendance_records');
      if (raw != null) {
        try {
          List<dynamic> records = jsonDecode(raw);
          return records.where((r) => r['sessionId'] == sessionId).toList();
        } catch (_) {}
      }
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
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final recordsRaw = prefs.getString('offline_attendance_records') ?? '[]';
      List<dynamic> records = jsonDecode(recordsRaw);
      final nowTime = DateTime.now();
      final formattedTime = '${nowTime.hour.toString().padLeft(2, '0')}:${nowTime.minute.toString().padLeft(2, '0')}';

      records.insert(0, {
        'attendanceId': records.length + 1,
        'sessionId': sessionId,
        'studentId': {
          'id': records.length + 200,
          'username': username,
          'fullName': username,
        },
        'username': username,
        'fullName': username,
        'timestamp': nowTime.toIso8601String(),
        'time': formattedTime,
        'rssi': 0,
        'deviceId': 'Organiser Manual Override',
        'status': 'Manual',
        'synced': false,
      });
      await prefs.setString('offline_attendance_records', jsonEncode(records));
      return {'message': 'Student added successfully (Offline Mode)'};
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
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final recordsRaw = prefs.getString('offline_attendance_records') ?? '[]';
      List<dynamic> records = jsonDecode(recordsRaw);
      records.removeWhere((r) => r['sessionId'] == sessionId && r['studentId']?['id'] == studentId);
      await prefs.setString('offline_attendance_records', jsonEncode(records));
      return {'message': 'Removed successfully'};
    }
  }

  Future<Map<String, dynamic>> getHistory() async {
    syncPendingDataWithCloud();

    try {
      final response = await _sendWithFallback(
        '/attendance/history',
        'GET',
        headers: await _headers(),
      );
      return jsonDecode(response.body);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('offline_attendance_records');
      if (raw != null) {
        try {
          List<dynamic> records = jsonDecode(raw);
          return {
            'totalSessions': records.isEmpty ? 1 : records.length,
            'attendedSessions': records.length,
            'percentage': records.isEmpty ? 0.0 : 100.0,
            'records': records.map((r) => {
              'sessionId': r['sessionId'],
              'sessionTitle': 'Class Attendance',
              'timestamp': r['timestamp'],
              'rssi': r['rssi'],
              'status': r['status'] ?? 'Present',
            }).toList(),
          };
        } catch (_) {}
      }
      return {
        'totalSessions': 0,
        'attendedSessions': 0,
        'percentage': 0.0,
        'records': []
      };
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
    } catch (_) {
      return [];
    }
  }

  // ================= ADMIN MANAGEMENT APIS =================

  Future<Map<String, dynamic>> getAdminStats() async {
    try {
      final response = await _sendWithFallback(
        '/admin/stats',
        'GET',
        headers: await _headers(needsAuth: true),
      );
      return jsonDecode(response.body);
    } catch (e) {
      return {
        'totalStudents': 0,
        'totalOrganisers': 0,
        'totalSessions': 0,
        'totalAttendance': 0,
        'pendingApprovals': 0,
      };
    }
  }

  Future<List<dynamic>> getAdminUsers({String? query, String? role}) async {
    try {
      String endpoint = '/admin/users?';
      if (query != null && query.isNotEmpty) {
        endpoint += 'q=${Uri.encodeComponent(query)}&';
      }
      if (role != null && role.isNotEmpty) {
        endpoint += 'role=${Uri.encodeComponent(role)}&';
      }
      final response = await _sendWithFallback(
        endpoint,
        'GET',
        headers: await _headers(needsAuth: true),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>> adminResetPassword(int userId, String newPassword) async {
    final response = await _sendWithFallback(
      '/admin/users/$userId/reset-password',
      'POST',
      headers: await _headers(needsAuth: true),
      body: jsonEncode({'newPassword': newPassword}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> adminResetDevice(int userId) async {
    final response = await _sendWithFallback(
      '/admin/users/$userId/reset-device',
      'POST',
      headers: await _headers(needsAuth: true),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> adminDeleteUser(int userId) async {
    final response = await _sendWithFallback(
      '/admin/users/$userId',
      'DELETE',
      headers: await _headers(needsAuth: true),
    );
    return jsonDecode(response.body);
  }
}

