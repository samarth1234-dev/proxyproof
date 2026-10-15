import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/api_service.dart';
import 'package:device_info_plus/device_info_plus.dart';

class StudentScreen extends StatefulWidget {
  @override
  _StudentScreenState createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> {
  final _api = ApiService();
  bool _scanning = false;
  String _status = 'Idle';

  void _startScanning() async {
    setState(() { _scanning = true; _status = 'Scanning for Organiser...'; });
    
    // Start BLE Scan
    FlutterBluePlus.startScan(timeout: Duration(seconds: 15));
    
    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        // In a real app, check for a specific Service UUID
        if (r.device.platformName == 'ProxyProof-Organiser') {
          final deviceId = await _getDeviceId();
          final res = await _api.markAttendance(
            'SESSION_ID_FROM_BLE_PACKET', 
            'TOKEN_FROM_BLE_PACKET', 
            r.rssi, 
            deviceId
          );
          setState(() {
            _status = res.containsKey('message') ? res['message'] : 'Error';
          });
          FlutterBluePlus.stopScan();
          break;
        }
      }
    });
  }

  Future<String> _getDeviceId() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
    return androidInfo.id; // Simplified
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Student Attendance')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Status: $_status'),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _scanning ? null : _startScanning, 
              child: Text(_scanning ? 'Scanning...' : 'Mark Attendance')
            ),
          ],
        ),
      ),
    );
  }
}
