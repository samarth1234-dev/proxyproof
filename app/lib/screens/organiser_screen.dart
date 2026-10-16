import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class OrganiserScreen extends StatefulWidget {
  const OrganiserScreen({Key? key}) : super(key: key);

  @override
  _OrganiserScreenState createState() => _OrganiserScreenState();
}

class _OrganiserScreenState extends State<OrganiserScreen> {
  final _api = ApiService();

  // Session state
  bool _isSessionActive = false;
  int? _sessionId;
  String _sessionTitle = 'Class Attendance';
  String _currentToken = '------';
  DateTime? _expiresAt;
  int _secondsRemaining = 300;

  // Live data
  List<dynamic> _attendanceList = [];
  List<dynamic> _pendingApprovals = [];
  Timer? _rotationTimer;
  Timer? _countdownTimer;
  Timer? _dashboardPollTimer;

  // Token rotation animation
  int _tokenSecondsLeft = 8;
  Timer? _tokenCountdownTimer;

  @override
  void initState() {
    super.initState();
    _checkActiveSession();
    _loadPendingApprovals();
  }

  @override
  void dispose() {
    _stopTimers();
    super.dispose();
  }

  void _stopTimers() {
    _rotationTimer?.cancel();
    _countdownTimer?.cancel();
    _dashboardPollTimer?.cancel();
    _tokenCountdownTimer?.cancel();
  }

  void _checkActiveSession() async {
    final active = await _api.getActiveSession();
    if (active['active'] == true && mounted) {
      setState(() {
        _isSessionActive = true;
        _sessionId = active['sessionId'];
        _sessionTitle = active['title'] ?? 'Active Session';
        _currentToken = active['currentToken'] ?? '------';
        if (active['expiresAt'] != null) {
          _expiresAt = DateTime.tryParse(active['expiresAt']);
          if (_expiresAt != null) {
            _secondsRemaining = max(0, _expiresAt!.difference(DateTime.now().toUtc()).inSeconds);
          }
        }
      });
      _startRotation();
      _startDashboardUpdates();
      _startCountdown();
    }
  }

  void _loadPendingApprovals() async {
    final list = await _api.getPendingApprovals();
    if (mounted) {
      setState(() {
        _pendingApprovals = list;
      });
    }
  }

  void _startSessionPrompt() {
    final titleController = TextEditingController(text: 'Computer Networks - Lec 7');
    int selectedMinutes = 5;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text(
            'Start Attendance Session',
            style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Lecture Title / Subject:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              TextField(
                controller: titleController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF2A2A44),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.class_, color: Color(0xFF6C63FF)),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Broadcast Duration:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [3, 5, 10, 15].map((m) {
                  final isSel = selectedMinutes == m;
                  return ChoiceChip(
                    label: Text('$m min'),
                    selected: isSel,
                    selectedColor: const Color(0xFF6C63FF),
                    backgroundColor: const Color(0xFF2A2A44),
                    labelStyle: TextStyle(color: isSel ? Colors.white : Colors.white70),
                    onSelected: (val) {
                      if (val) setDialogState(() => selectedMinutes = m);
                    },
                  );
                }).toList(),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                final res = await _api.startSession(
                  title: titleController.text.trim().isEmpty ? 'Lecture' : titleController.text.trim(),
                  durationMinutes: selectedMinutes,
                );
                if (res.containsKey('sessionId') && mounted) {
                  setState(() {
                    _isSessionActive = true;
                    _sessionId = res['sessionId'];
                    _sessionTitle = res['title'];
                    _currentToken = res['currentToken'];
                    _secondsRemaining = selectedMinutes * 60;
                  });
                  _startRotation();
                  _startDashboardUpdates();
                  _startCountdown();
                } else if (res.containsKey('error')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(backgroundColor: Colors.redAccent, content: Text(res['error'])),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
              child: const Text('Start Broadcast'),
            ),
          ],
        ),
      ),
    );
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_secondsRemaining <= 1) {
        timer.cancel();
        _endSession();
      } else {
        setState(() => _secondsRemaining--);
      }
    });
  }

  void _startRotation() {
    _tokenSecondsLeft = 8;
    _tokenCountdownTimer?.cancel();
    _tokenCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      if (_tokenSecondsLeft <= 1) {
        _tokenSecondsLeft = 8;
      } else {
        setState(() => _tokenSecondsLeft--);
      }
    });

    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(const Duration(seconds: 8), (timer) async {
      if (!_isSessionActive || _sessionId == null) {
        timer.cancel();
        return;
      }
      final newToken = (100000 + Random().nextInt(900000)).toString();
      final res = await _api.rotateToken(sessionId: _sessionId!, newToken: newToken);
      if (res['success'] == true && mounted) {
        setState(() {
          _currentToken = newToken;
          _tokenSecondsLeft = 8;
        });
      }
    });
  }

  void _startDashboardUpdates() {
    _dashboardPollTimer?.cancel();
    // Poll dashboard every 3 seconds for instant real-time live attendance
    _dashboardPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!_isSessionActive || _sessionId == null) {
        timer.cancel();
        return;
      }
      final list = await _api.getDashboard(_sessionId!);
      if (mounted) {
        setState(() {
          _attendanceList = list;
        });
      }
    });
  }

  void _endSession() async {
    if (_sessionId != null) {
      await _api.closeSession(_sessionId!);
    }
    _stopTimers();
    if (mounted) {
      setState(() {
        _isSessionActive = false;
        _currentToken = 'CLOSED';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Attendance session closed successfully.')),
      );
    }
  }

  void _showManualAddDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Manual Student Attendance', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter Student Roll No / Username to mark present manually:', style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'e.g. 21BCE1004',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF2A2A44),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                prefixIcon: const Icon(Icons.person_add, color: Color(0xFF00D2FF)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () async {
              final username = controller.text.trim();
              if (username.isEmpty || _sessionId == null) return;
              Navigator.pop(ctx);
              final res = await _api.manualAdd(sessionId: _sessionId!, username: username);
              if (res.containsKey('error')) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text(res['error'])));
              } else {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.green, content: Text(res['message'])));
                final updated = await _api.getDashboard(_sessionId!);
                if (mounted) setState(() => _attendanceList = updated);
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
            child: const Text('Mark Present'),
          ),
        ],
      ),
    );
  }

  void _removeStudent(int studentId, String username) async {
    if (_sessionId == null) return;
    final res = await _api.manualRemove(sessionId: _sessionId!, studentId: studentId);
    if (res.containsKey('message') && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed $username from attendance.')),
      );
      final updated = await _api.getDashboard(_sessionId!);
      setState(() => _attendanceList = updated);
    }
  }

  void _exportCsv() async {
    if (_sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No session active or selected to export.')),
      );
      return;
    }
    final url = await _api.getExportUrl(_sessionId!);
    try {
      final res = await http.get(Uri.parse(url));
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E34),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Attendance CSV Export', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Direct Download URL:\n$url', style: const TextStyle(color: Color(0xFF00D2FF), fontSize: 12)),
                  const SizedBox(height: 12),
                  const Text('Preview (First few lines):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFF131326), borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      res.body.isEmpty ? 'No attendance records' : res.body.split('\n').take(6).join('\n'),
                      style: const TextStyle(fontFamily: 'monospace', color: Colors.white70, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error: $e')));
    }
  }

  void _showPendingApprovalsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: Text('Device Binding Approvals', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: double.maxFinite,
            child: _pendingApprovals.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(child: Text('No pending device switch requests', style: TextStyle(color: Colors.white54))),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _pendingApprovals.length,
                    itemBuilder: (context, i) {
                      final item = _pendingApprovals[i];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A44),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['fullName'] ?? item['username'],
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Device: ${item['deviceModel'] ?? 'Unknown'} (${item['deviceId']})',
                              style: const TextStyle(color: Colors.white60, fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton(
                                  onPressed: () async {
                                    await _api.approveDevice(userId: item['id'], approve: false);
                                    _loadPendingApprovals();
                                    Navigator.pop(ctx);
                                  },
                                  style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                                  child: const Text('Reject'),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed: () async {
                                    await _api.approveDevice(userId: item['id'], approve: true);
                                    _loadPendingApprovals();
                                    Navigator.pop(ctx);
                                  },
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                                  child: const Text('Approve'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done', style: TextStyle(color: Colors.white70))),
          ],
        ),
      ),
    );
  }

  void _logout() async {
    await _api.logout();
    if (mounted) Navigator.pushReplacementNamed(context, '/');
  }

  String _formatTime(int totalSeconds) {
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
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
            Text('Organiser Center', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
            Text('Anti-Proxy BLE Broadcast', style: GoogleFonts.poppins(fontSize: 12, color: Colors.white60)),
          ],
        ),
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.devices_other, color: Colors.white70),
                tooltip: 'Device Approvals',
                onPressed: _showPendingApprovalsDialog,
              ),
              if (_pendingApprovals.isNotEmpty)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: Colors.orangeAccent, shape: BoxShape.circle),
                    child: Text('${_pendingApprovals.length}', style: const TextStyle(fontSize: 10, color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: Container(
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
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Status Card & Rotating Security Token Badge
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _isSessionActive
                          ? [const Color(0xFF2C2454), const Color(0xFF1E1E38)]
                          : [const Color(0xFF25253C), const Color(0xFF1A1A2C)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: _isSessionActive ? const Color(0xFF6C63FF).withOpacity(0.2) : Colors.black26,
                        blurRadius: 15,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _sessionTitle,
                                  style: GoogleFonts.poppins(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _isSessionActive ? Colors.greenAccent : Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _isSessionActive ? 'BROADCASTING • ${_formatTime(_secondsRemaining)}' : 'Session Inactive',
                                      style: TextStyle(
                                        color: _isSessionActive ? Colors.greenAccent : Colors.white54,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _isSessionActive ? _endSession : _startSessionPrompt,
                            icon: Icon(_isSessionActive ? Icons.stop_circle : Icons.play_arrow),
                            label: Text(_isSessionActive ? 'End' : 'Start'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isSessionActive ? Colors.redAccent : const Color(0xFF6C63FF),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ],
                      ),

                      if (_isSessionActive) ...[
                        const Divider(color: Colors.white12, height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Anti-Proxy Rotating Token', style: TextStyle(color: Colors.white60, fontSize: 11)),
                                const SizedBox(height: 4),
                                Text(
                                  _currentToken,
                                  style: GoogleFonts.poppins(
                                    color: const Color(0xFF00D2FF),
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 4,
                                  ),
                                ),
                              ],
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text('Rotates in ${_tokenSecondsLeft}s', style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                const SizedBox(height: 6),
                                SizedBox(
                                  width: 60,
                                  child: LinearProgressIndicator(
                                    value: _tokenSecondsLeft / 8.0,
                                    backgroundColor: Colors.white12,
                                    color: const Color(0xFF00D2FF),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 18),

                // Control Bar: Live Counter & Action Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Text('Live Attendance', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00D2FF).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_attendanceList.length}',
                            style: const TextStyle(color: Color(0xFF00D2FF), fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        if (_isSessionActive)
                          IconButton(
                            icon: const Icon(Icons.person_add_alt_1, color: Color(0xFF00D2FF)),
                            tooltip: 'Manual Add',
                            onPressed: _showManualAddDialog,
                          ),
                        IconButton(
                          icon: const Icon(Icons.download, color: Colors.greenAccent),
                          tooltip: 'Export CSV',
                          onPressed: _exportCsv,
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                // Live Student Feed List
                Expanded(
                  child: _attendanceList.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _isSessionActive ? Icons.wifi_tethering : Icons.hourglass_empty,
                                size: 50,
                                color: Colors.white24,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _isSessionActive
                                    ? 'Broadcasting BLE signal...\nNearby verified students will appear here automatically.'
                                    : 'No active attendance session.\nTap "Start" to begin taking attendance.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white38, height: 1.4),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: _attendanceList.length,
                          itemBuilder: (ctx, i) {
                            final item = _attendanceList[i];
                            final student = item['studentId'] ?? {};
                            final username = student['username'] ?? 'Student';
                            final fullName = student['fullName'] ?? username;
                            final time = item['timestamp'] ?? '';
                            final rssi = item['rssi'] ?? 0;
                            final studentId = student['id'];

                            return Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF222238),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: const Color(0xFF6C63FF),
                                    child: Text(
                                      fullName.isNotEmpty ? fullName[0].toUpperCase() : 'S',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          fullName,
                                          style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                                        ),
                                        Text(
                                          'Roll: $username • ${time.length > 19 ? time.substring(11, 19) : time}',
                                          style: const TextStyle(color: Colors.white54, fontSize: 11),
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
                                          color: Colors.greenAccent.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          rssi != 0 ? '$rssi dBm' : 'Manual',
                                          style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_isSessionActive && studentId != null)
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                                      tooltip: 'Remove',
                                      onPressed: () => _removeStudent(studentId, username),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
