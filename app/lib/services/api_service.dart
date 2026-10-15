import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  final String baseUrl = 'http://YOUR_SERVER_IP:3000';

  Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('token');
  }

  Future<void> saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      body: jsonEncode({'username': username, 'password': password}),
      headers: {'Content-Type': 'application/json'},
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> register(String username, String password, String role) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      body: jsonEncode({'username': username, 'password': password, 'role': role}),
      headers: {'Content-Type': 'application/json'},
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> bindDevice(String deviceId) async {
    final token = await getToken();
    final response = await http.put(
      Uri.parse('$baseUrl/user/bind-device'),
      headers: {'Authorization': token!, 'Content-Type': 'application/json'},
      body: jsonEncode({'deviceId': deviceId}),
    );
    return jsonDecode(response.body);
  }

  Future<Map<String, dynamic>> startSession() async {
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/session/start'),
      headers: {'Authorization': token!, 'Content-Type': 'application/json'},
    );
    return jsonDecode(response.body);
  }

  Future<void> rotateToken(String sessionId, String newToken) async {
    final token = await getToken();
    await http.put(
      Uri.parse('$baseUrl/session/rotate-token'),
      headers: {'Authorization': token!, 'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'newToken': newToken}),
    );
  }

  Future<Map<String, dynamic>> markAttendance(String sessionId, String token, int rssi, String deviceId) async {
    final tokenAuth = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl/attendance/mark'),
      headers: {'Authorization': tokenAuth!, 'Content-Type': 'application/json'},
      body: jsonEncode({'sessionId': sessionId, 'token': token, 'rssi': rssi, 'deviceId': deviceId}),
    );
    return jsonDecode(response.body);
  }

  Future<List<dynamic>> getDashboard(String sessionId) async {
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl/attendance/dashboard/$sessionId'),
      headers: {'Authorization': token!},
    );
    return jsonDecode(response.body);
  }
}
