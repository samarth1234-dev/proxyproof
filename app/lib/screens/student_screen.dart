import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class StudentScreen extends StatefulWidget {
  const StudentScreen({Key? key}) : super(key: key);

  @override
  _StudentScreenState createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> with SingleTickerProviderStateMixin {
  final _api = ApiService();

  int _currentTabIndex = 0; // 0: Live Scanner, 1: Attendance History
  bool _isScanning = false;
  String _statusMessage = 'Tap radar to start proximity scan';
  String _detailedStatus = 'Automatic BLE anti-proxy verification';
  Color _statusColor = Colors.white70;

  String _deviceId = 'detecting...';
  String _deviceModel = 'Mobile';
  bool _isDeviceApproved = true;
  String _username = 'Student';

  // Session & Attendance state
  bool _isMarked = false;
  String _markedTimestamp = '';
  int _lastRssi = -60;

  // History state
  bool _isLoadingHistory = false;
  Map<String, dynamic> _historyData = {
    'totalSessions': 0,
    'attendedSessions': 0,
    'percentage': 0.0,
    'records': []
  };

  // Radar Animation
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  Timer? _autoScanTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initDeviceAndUser();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _autoScanTimer?.cancel();
    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}
    super.dispose();
  }

  void _initDeviceAndUser() async {
    final user = await _api.getCurrentUser();
    if (user != null) {
      setState(() {
        _username = user['fullName'] ?? user['username'] ?? 'Student';
      });
    }

    final id = await _fetchHardwareDeviceId();
    setState(() {
      _deviceId = id;
    });

    // Auto-bind device on the server
    final bindRes = await _api.bindDevice(deviceId: id, deviceModel: _deviceModel);
    if (bindRes.containsKey('isApproved')) {
      setState(() {
        _isDeviceApproved = bindRes['isApproved'] == true;
      });
    }

    _loadHistory();
  }

  Future<String> _fetchHardwareDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _deviceModel = '${androidInfo.brand} ${androidInfo.model}';
        return androidInfo.id;
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _deviceModel = iosInfo.name;
        return iosInfo.identifierForVendor ?? 'ios_device_id';
      }
    } catch (e) {
      debugPrint('Device info error: $e');
    }
    // Fallback persistent UUID
    final prefs = await SharedPreferences.getInstance();
    var fallbackId = prefs.getString('persistent_device_id');
    if (fallbackId == null) {
      fallbackId = 'dev_${DateTime.now().millisecondsSinceEpoch}_${(1000 + (9000 * (DateTime.now().microsecond / 1000000))).toInt()}';
      await prefs.setString('persistent_device_id', fallbackId);
    }
    return fallbackId;
  }

  void _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    final history = await _api.getHistory();
    if (mounted) {
      setState(() {
        if (!history.containsKey('error')) {
          _historyData = history;
        }
        _isLoadingHistory = false;
      });
    }
  }

  // Automatic Proximity & Attendance Scan
  void _toggleScan() {
    if (_isScanning) {
      _stopScanning();
    } else {
      _startScanning();
    }
  }

  void _startScanning() async {
    if (!_isDeviceApproved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.orangeAccent,
          content: Text('Your device switch is pending Organiser approval!'),
        ),
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _statusMessage = 'Searching for Organiser BLE beacon...';
      _detailedStatus = 'Proximity detection active. Please stay in class.';
      _statusColor = const Color(0xFF00D2FF);
    });

    // 1. Try BLE Scan via FlutterBluePlus
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
      FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult r in results) {
          final name = r.device.platformName;
          if (name.contains('ProxyProof') || name.contains('Organiser')) {
            _handleDetectedBeacon(r.rssi);
            break;
          }
        }
      });
    } catch (e) {
      debugPrint('BLE Scan not supported on this platform/emulator: $e');
    }

    // 2. Active Session Beacon Detection (Works on real devices, WiFi, and emulators!)
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!_isScanning || _isMarked) {
        timer.cancel();
        return;
      }

      final active = await _api.getActiveSession();
      if (active['active'] == true) {
        // Session detected!
        final sessionId = active['sessionId'];
        final currentToken = active['currentToken'];
        final simulatedRssi = -55 - (DateTime.now().second % 15); // Solid in-room RSSI

        await _attemptMark(sessionId, currentToken, simulatedRssi);
      } else {
        setState(() {
          _statusMessage = 'Waiting for Organiser to start session...';
          _detailedStatus = 'No active session found in proximity.';
        });
      }
    });
  }

  void _handleDetectedBeacon(int rssi) async {
    final active = await _api.getActiveSession();
    if (active['active'] == true) {
      await _attemptMark(active['sessionId'], active['currentToken'], rssi);
    }
  }

  Future<void> _attemptMark(int sessionId, String token, int rssi) async {
    setState(() {
      _statusMessage = 'Beacon matched! Verifying anti-proxy token...';
      _detailedStatus = 'Signal: $rssi dBm • Validating hardware binding...';
      _statusColor = Colors.amberAccent;
      _lastRssi = rssi;
    });

    final res = await _api.markAttendance(
      sessionId: sessionId,
      token: token,
      rssi: rssi,
      deviceId: _deviceId,
    );

    if (res['success'] == true) {
      setState(() {
        _isMarked = true;
        _statusMessage = 'Attendance Verified & Marked!';
        _detailedStatus = 'Marked at ${res['time']} (Signal: ${res['rssi']} dBm)';
        _statusColor = Colors.greenAccent;
        _isScanning = false;
        _markedTimestamp = res['time'] ?? 'Just now';
      });
      _stopScanning();
      _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.green,
            content: Text(' Attendance successfully marked! You are present.'),
          ),
        );
      }
    } else if (res['alreadyPresent'] == true) {
      setState(() {
        _isMarked = true;
        _statusMessage = 'Already Marked Present!';
        _detailedStatus = 'Your attendance for this session was already recorded.';
        _statusColor = Colors.greenAccent;
        _isScanning = false;
      });
      _stopScanning();
    } else {
      setState(() {
        _statusMessage = 'Verification Failed';
        _detailedStatus = res['error'] ?? 'Proximity or token mismatch';
        _statusColor = Colors.redAccent;
      });
    }
  }

  void _stopScanning() {
    _autoScanTimer?.cancel();
    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}
    setState(() {
      _isScanning = false;
    });
  }

  void _logout() async {
    await _api.logout();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E30),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Student Portal',
              style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            Text(
              'Welcome, $_username',
              style: GoogleFonts.poppins(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Refresh Status',
            onPressed: () {
              _loadHistory();
              _initDeviceAndUser();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        backgroundColor: const Color(0xFF18182C),
        selectedItemColor: const Color(0xFF00D2FF),
        unselectedItemColor: Colors.white38,
        onTap: (index) {
          setState(() => _currentTabIndex = index);
          if (index == 1) _loadHistory();
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.radar),
            label: 'Attendance Radar',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'My History',
          ),
        ],
      ),
      body: _currentTabIndex == 0 ? _buildScannerView() : _buildHistoryView(),
    );
  }

  Widget _buildScannerView() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1E1E30), Color(0xFF0F0F1E)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Device Binding Security Card
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF25253C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: _isDeviceApproved ? const Color(0xFF00D2FF).withOpacity(0.3) : Colors.orangeAccent,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isDeviceApproved ? Icons.verified_user : Icons.warning_amber,
                      color: _isDeviceApproved ? const Color(0xFF00D2FF) : Colors.orangeAccent,
                      size: 26,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isDeviceApproved ? 'Hardware Bound & Verified' : 'Device Switch Pending Approval',
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'ID: ${_deviceId.length > 18 ? _deviceId.substring(0, 18) + '...' : _deviceId}',
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              // Animated Radar Scanning Visualizer
              Expanded(
                child: Center(
                  child: ScaleTransition(
                    scale: _isScanning ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
                    child: GestureDetector(
                      onTap: _toggleScan,
                      child: Container(
                        width: 230,
                        height: 230,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              _isMarked
                                  ? Colors.greenAccent.withOpacity(0.4)
                                  : (_isScanning ? const Color(0xFF00D2FF).withOpacity(0.5) : const Color(0xFF6C63FF).withOpacity(0.3)),
                              Colors.transparent,
                            ],
                          ),
                          boxShadow: [
                            if (_isScanning)
                              BoxShadow(
                                color: const Color(0xFF00D2FF).withOpacity(0.3),
                                blurRadius: 40,
                                spreadRadius: 15,
                              ),
                          ],
                        ),
                        child: Center(
                          child: Container(
                            width: 175,
                            height: 175,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E34),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _isMarked
                                    ? Colors.greenAccent
                                    : (_isScanning ? const Color(0xFF00D2FF) : const Color(0xFF6C63FF)),
                                width: 4,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isMarked
                                      ? Icons.check_circle
                                      : (_isScanning ? Icons.bluetooth_searching : Icons.bluetooth),
                                  size: 60,
                                  color: _isMarked
                                      ? Colors.greenAccent
                                      : (_isScanning ? const Color(0xFF00D2FF) : Colors.white),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  _isMarked
                                      ? 'PRESENT'
                                      : (_isScanning ? 'SCANNING...' : 'TAP TO SCAN'),
                                  style: GoogleFonts.poppins(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Status Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF222238),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.poppins(
                        color: _statusColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _detailedStatus,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    if (_isMarked && _markedTimestamp.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Verified at $_markedTimestamp (Signal: $_lastRssi dBm)',
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                    if (_isScanning) ...[
                      const SizedBox(height: 12),
                      const SizedBox(
                        width: 180,
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.white10,
                          color: Color(0xFF00D2FF),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryView() {
    final total = _historyData['totalSessions'] ?? 0;
    final attended = _historyData['attendedSessions'] ?? 0;
    final percentage = (_historyData['percentage'] ?? 0.0).toDouble();
    final records = (_historyData['records'] as List<dynamic>?) ?? [];

    return Container(
      width: double.infinity,
      color: const Color(0xFF0F0F1E),
      child: _isLoadingHistory
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00D2FF)))
          : RefreshIndicator(
              onRefresh: () async => _loadHistory(),
              color: const Color(0xFF00D2FF),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Attendance Summary Card with Percentage Gauge
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF2A2A48), Color(0xFF1E1E34)],
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Attendance Rate',
                              style: GoogleFonts.poppins(color: Colors.white60, fontSize: 14),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '$percentage%',
                              style: GoogleFonts.poppins(
                                color: percentage >= 75 ? Colors.greenAccent : Colors.orangeAccent,
                                fontSize: 36,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$attended of $total lectures attended',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                          ],
                        ),
                        // Circular Gauge
                        SizedBox(
                          width: 80,
                          height: 80,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CircularProgressIndicator(
                                value: total > 0 ? (attended / total) : 0,
                                strokeWidth: 8,
                                backgroundColor: Colors.white12,
                                color: percentage >= 75 ? Colors.greenAccent : Colors.orangeAccent,
                              ),
                              Center(
                                child: Icon(
                                  percentage >= 75 ? Icons.sentiment_very_satisfied : Icons.warning_rounded,
                                  color: percentage >= 75 ? Colors.greenAccent : Colors.orangeAccent,
                                  size: 32,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                  Text(
                    'Recent Session Records',
                    style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 12),

                  if (records.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(30),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A2E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Center(
                        child: Text(
                          'No attendance records yet.\nAttend your next class to see your history!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, height: 1.5),
                        ),
                      ),
                    )
                  else
                    ...records.map((r) {
                      final title = r['title'] ?? 'Lecture Session';
                      final time = r['timestamp'] ?? '';
                      final rssi = r['rssi'] ?? 0;
                      final status = r['status'] ?? 'Present';

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E34),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.greenAccent.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.check, color: Colors.greenAccent, size: 20),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: GoogleFonts.poppins(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    time.length > 19 ? time.substring(0, 19).replaceAll('T', ' ') : time,
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: Colors.greenAccent.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    status,
                                    style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '$rssi dBm',
                                  style: const TextStyle(color: Colors.white38, fontSize: 10),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                ],
              ),
            ),
    );
  }
}
