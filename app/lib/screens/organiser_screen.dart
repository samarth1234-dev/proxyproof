import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import '../services/api_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class OrganiserScreen extends StatefulWidget {
  @override
  _OrganiserScreenState createState() => _OrganiserScreenState();
}

class _OrganiserScreenState extends State<OrganiserScreen> {
  final _api = ApiService();
  String? _sessionId;
  List<dynamic> _attendance = [];
  Timer? _tokenTimer;

  void _startSession() async {
    final res = await _api.startSession();
    setState(() {
      _sessionId = res['_id'];
    });
    _startRotation();
    _startDashboardUpdate();
  }

  void _startRotation() {
    _tokenTimer = Timer.periodic(Duration(seconds: 10), (timer) async {
      final newToken = Random().nextInt(1000000).toString();
      await _api.rotateToken(_sessionId!, newToken);
      // In a real app, we would update the BLE advertisement packet here.
      // FlutterBluePlus supports starting advertising on some Android devices.
    });
  }

  void _startDashboardUpdate() {
    Timer.periodic(Duration(seconds: 5), (timer) async {
      if (_sessionId == null) return;
      final list = await _api.getDashboard(_sessionId!);
      setState(() {
        _attendance = list;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Organiser Dashboard')),
      body: Column(
        children: [
          if (_sessionId == null)
            Center(child: ElevatedButton(onPressed: _startSession, child: Text('Start Attendance Session')))
          else
            Expanded(
              child: ListView.builder(
                itemCount: _attendance.length,
                itemBuilder: (ctx, i) => ListTile(
                  title: Text(_attendance[i]['studentId']['username']),
                  subtitle: Text('RSSI: ${_attendance[i]['rssi']}'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
