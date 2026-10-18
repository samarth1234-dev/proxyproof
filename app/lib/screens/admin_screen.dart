import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/api_service.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({Key? key}) : super(key: key);

  @override
  _AdminScreenState createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  final _api = ApiService();
  final _searchController = TextEditingController();

  Map<String, dynamic> _stats = {};
  List<dynamic> _users = [];
  bool _isLoading = true;
  String _selectedRoleFilter = ''; // '' for all, 'student', 'organiser'

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final stats = await _api.getAdminStats();
    final users = await _api.getAdminUsers(
      query: _searchController.text.trim(),
      role: _selectedRoleFilter,
    );
    if (mounted) {
      setState(() {
        _stats = stats;
        _users = users;
        _isLoading = false;
      });
    }
  }

  void _showResetPasswordDialog(Map<String, dynamic> user) {
    final pwdController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.lock_reset, color: Color(0xFF00D2FF)),
            const SizedBox(width: 10),
            Text('Reset Password', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set a new password for ${user['username']} (${user['fullName'] ?? 'User'}):',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: pwdController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Enter new password (min 4 chars)',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF2A2A40),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.vpn_key, color: Color(0xFF6C63FF)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () async {
              final newPass = pwdController.text.trim();
              if (newPass.length < 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password must be at least 4 characters long')),
                );
                return;
              }
              Navigator.pop(ctx);
              final res = await _api.adminResetPassword(user['id'], newPass);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: res['success'] == true ? const Color(0xFF10B981) : Colors.red,
                    content: Text(res['message'] ?? res['error'] ?? 'Password reset successfully'),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
            child: const Text('Save Password'),
          ),
        ],
      ),
    );
  }

  void _showResetDeviceDialog(Map<String, dynamic> user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.phonelink_erase, color: Color(0xFFFFB7A9)),
            const SizedBox(width: 10),
            Text('Unbind Phone Lock', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        content: Text(
          'Are you sure you want to unbind the device for "${user['username']}"?\n\n'
          'Current Device: ${user['deviceModel'] ?? user['deviceId'] ?? 'None'}\n\n'
          'This removes the hardware lock so the student can register their new phone on next login.',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await _api.adminResetDevice(user['id']);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: const Color(0xFF10B981),
                    content: Text(res['message'] ?? 'Device unlinked successfully'),
                  ),
                );
                _loadData();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00D2FF), foregroundColor: Colors.black),
            child: const Text('Unbind Phone'),
          ),
        ],
      ),
    );
  }

  void _showDeleteUserDialog(Map<String, dynamic> user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E30),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.delete_forever, color: Colors.redAccent),
            const SizedBox(width: 10),
            Text('Delete User', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white)),
          ],
        ),
        content: Text(
          '⚠️ DANGER: Permanently delete "${user['username']}" (${user['role']})?\n\n'
          'All attendance records, sessions, and device bindings will be permanently wiped. This cannot be undone!',
          style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await _api.adminDeleteUser(user['id']);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: res['success'] == true ? Colors.redAccent : Colors.red,
                    content: Text(res['message'] ?? res['error'] ?? 'User deleted'),
                  ),
                );
                _loadData();
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Permanently Delete'),
          ),
        ],
      ),
    );
  }

  void _approveDevice(int userId, bool approve) async {
    final res = await _api.approveDevice(userId: userId, approve: approve);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res['message'] ?? 'Device updated')),
      );
      _loadData();
    }
  }

  void _logout() async {
    await _api.logout();
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/');
    }
  }

  Widget _buildStatChip(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E30),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 10, color: Colors.white54, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E30),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.admin_panel_settings, color: Color(0xFF00D2FF)),
            const SizedBox(width: 8),
            Text('ProxyProof Admin', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: 'Refresh Data',
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
            tooltip: 'Logout',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF)))
          : RefreshIndicator(
              onRefresh: _loadData,
              color: const Color(0xFF6C63FF),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // --- STATS HORIZONTAL SCROLL ---
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildStatChip('STUDENTS', '${_stats['totalStudents'] ?? 0}', const Color(0xFF00D2FF)),
                        const SizedBox(width: 10),
                        _buildStatChip('FACULTY', '${_stats['totalOrganisers'] ?? 0}', const Color(0xFF6C63FF)),
                        const SizedBox(width: 10),
                        _buildStatChip('SESSIONS', '${_stats['totalSessions'] ?? 0}', const Color(0xFF10B981)),
                        const SizedBox(width: 10),
                        _buildStatChip('ATTENDANCE', '${_stats['totalAttendance'] ?? 0}', const Color(0xFFFFB7A9)),
                        const SizedBox(width: 10),
                        _buildStatChip('PENDING APPROVALS', '${_stats['pendingApprovals'] ?? 0}', const Color(0xFFF59E0B)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  // --- SEARCH & FILTERS ---
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (_) => _loadData(),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            hintText: 'Search roll no, name, or phone ID…',
                            hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                            prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
                            filled: true,
                            fillColor: const Color(0xFF1E1E30),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // --- ROLE FILTER CHIPS ---
                  Row(
                    children: [
                      FilterChip(
                        label: const Text('All'),
                        selected: _selectedRoleFilter == '',
                        onSelected: (_) {
                          setState(() => _selectedRoleFilter = '');
                          _loadData();
                        },
                        selectedColor: const Color(0xFF6C63FF),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Students'),
                        selected: _selectedRoleFilter == 'student',
                        onSelected: (_) {
                          setState(() => _selectedRoleFilter = 'student');
                          _loadData();
                        },
                        selectedColor: const Color(0xFF00D2FF),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        label: const Text('Faculty'),
                        selected: _selectedRoleFilter == 'organiser',
                        onSelected: (_) {
                          setState(() => _selectedRoleFilter = 'organiser');
                          _loadData();
                        },
                        selectedColor: const Color(0xFF10B981),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // --- USER DIRECTORY CARDS ---
                  Text(
                    'USER DIRECTORY (${_users.length})',
                    style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white54),
                  ),
                  const SizedBox(height: 8),

                  if (_users.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(32),
                      alignment: Alignment.center,
                      child: const Text('No users found.', style: TextStyle(color: Colors.white38)),
                    )
                  else
                    ..._users.map((user) {
                      final isStudent = user['role'] == 'student';
                      final isAdmin = user['role'] == 'admin';
                      final hasDevice = user['deviceId'] != null && (user['deviceId'] as String).isNotEmpty;
                      final isApproved = user['isApproved'] == 1 || user['isApproved'] == true;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E30),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: !isApproved ? const Color(0xFFF59E0B) : const Color(0xFF2A2A40),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 18,
                                      backgroundColor: isAdmin
                                          ? const Color(0xFFF59E0B)
                                          : (isStudent ? const Color(0xFF00D2FF) : const Color(0xFF6C63FF)),
                                      child: Text(
                                        (user['username'] ?? 'U')[0].toUpperCase(),
                                        style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          user['username'] ?? '',
                                          style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: Colors.white),
                                        ),
                                        Text(
                                          user['fullName'] ?? user['username'] ?? '',
                                          style: const TextStyle(fontSize: 11, color: Colors.white54),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: (user['role'] == 'admin' ? Colors.amber : (isStudent ? const Color(0xFF00D2FF) : const Color(0xFF6C63FF))).withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    (user['role'] ?? 'user').toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: user['role'] == 'admin' ? Colors.amber : (isStudent ? const Color(0xFF00D2FF) : const Color(0xFF6C63FF)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(color: Color(0xFF2A2A40), height: 18),

                            // Device info
                            Row(
                              children: [
                                Icon(
                                  hasDevice ? Icons.smartphone : Icons.phone_android_outlined,
                                  size: 14,
                                  color: hasDevice ? Colors.white70 : Colors.white24,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    hasDevice
                                        ? '${user['deviceModel'] ?? 'Phone'} (${(user['deviceId'] as String).substring(0, user['deviceId'].length > 14 ? 14 : user['deviceId'].length)}…)'
                                        : 'No phone bound',
                                    style: TextStyle(fontSize: 11, color: hasDevice ? Colors.white70 : Colors.white24),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (hasDevice)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isApproved ? const Color(0xFF10B981).withOpacity(0.2) : Colors.amber.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      isApproved ? 'BOUND ✓' : 'PENDING APPROVAL',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        color: isApproved ? const Color(0xFF10B981) : Colors.amber,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),

                            if (isStudent)
                              Text(
                                'Attendance Marked: ${user['attendanceCount'] ?? 0} lectures',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF00D2FF)),
                              ),

                            const SizedBox(height: 10),

                            // Action buttons
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.key, size: 14),
                                  label: const Text('Reset Pass', style: TextStyle(fontSize: 11)),
                                  onPressed: () => _showResetPasswordDialog(user),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.white70,
                                    side: const BorderSide(color: Color(0xFF3A3A55)),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  ),
                                ),
                                if (hasDevice)
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.phonelink_erase, size: 14),
                                    label: const Text('Unbind Phone', style: TextStyle(fontSize: 11)),
                                    onPressed: () => _showResetDeviceDialog(user),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF00D2FF),
                                      side: const BorderSide(color: Color(0xFF00D2FF)),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    ),
                                  ),
                                if (!isApproved)
                                  ElevatedButton.icon(
                                    icon: const Icon(Icons.check, size: 14),
                                    label: const Text('Approve Phone', style: TextStyle(fontSize: 11)),
                                    onPressed: () => _approveDevice(user['id'], true),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    ),
                                  ),
                                if (!isAdmin)
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.delete, size: 14, color: Colors.redAccent),
                                    label: const Text('Delete', style: TextStyle(fontSize: 11, color: Colors.redAccent)),
                                    onPressed: () => _showDeleteUserDialog(user),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.redAccent),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    ),
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
