#!/usr/bin/env python3
"""
ProxyProof Backend Server
Handles authentication, hardware device binding, rotating anti-proxy tokens,
BLE/RSSI verification, real-time live attendance, and CSV export.
"""

from flask import Flask, request, jsonify, Response
from flask_cors import CORS
import sqlite3
import bcrypt
import jwt
import os
import random
import io
import csv
from datetime import datetime, timedelta

app = Flask(__name__)
CORS(app)

SECRET_KEY = os.environ.get("JWT_SECRET", "proxyproof-super-secret-key-2026")
DB_PATH = os.path.join(os.path.dirname(__file__), 'proxyproof.db')

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as conn:
        conn.execute('''
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                fullName TEXT,
                password TEXT NOT NULL,
                role TEXT NOT NULL, -- 'student', 'organiser', or 'admin'
                deviceId TEXT,
                deviceModel TEXT,
                isApproved INTEGER DEFAULT 1,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        # Seed default super admin if none exists
        admin = conn.execute("SELECT id FROM users WHERE role = 'admin'").fetchone()
        if not admin:
            default_pwd = os.environ.get("ADMIN_DEFAULT_PASSWORD", "admin123")
            hashed_admin = bcrypt.hashpw(default_pwd.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
            conn.execute(
                "INSERT INTO users (username, fullName, password, role, isApproved) VALUES (?, ?, ?, 'admin', 1)",
                ('admin', 'Super Administrator', hashed_admin)
            )
            print("🛡️ Default Super Admin seeded: username='admin', password='admin123'")

        conn.execute('''
            CREATE TABLE IF NOT EXISTS sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                organiserId INTEGER NOT NULL,
                title TEXT DEFAULT 'Lecture Attendance',
                durationMinutes INTEGER DEFAULT 5,
                currentToken TEXT NOT NULL,
                recentTokens TEXT DEFAULT '', -- comma-separated recent tokens for jitter grace period
                isActive INTEGER DEFAULT 1,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP,
                expiresAt DATETIME NOT NULL
            )
        ''')
        conn.execute('''
            CREATE TABLE IF NOT EXISTS attendance (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                sessionId INTEGER NOT NULL,
                studentId INTEGER NOT NULL,
                timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
                rssi INTEGER,
                deviceId TEXT,
                status TEXT DEFAULT 'Present',
                FOREIGN KEY(sessionId) REFERENCES sessions(id),
                FOREIGN KEY(studentId) REFERENCES users(id)
            )
        ''')
        conn.commit()

init_db()

def create_jwt(user_id, role, username):
    payload = {
        'id': user_id,
        'role': role,
        'username': username,
        'exp': datetime.utcnow() + timedelta(days=7)
    }
    return jwt.encode(payload, SECRET_KEY, algorithm='HS256')

def get_current_user():
    auth_header = request.headers.get('Authorization')
    if not auth_header:
        return None
    token = auth_header.replace('Bearer ', '').strip()
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=['HS256'])
    except Exception:
        return None

# ================= AUTHENTICATION =================

@app.route('/', methods=['GET'])
def index():
    return jsonify({
        'status': 'online',
        'app': 'ProxyProof API',
        'version': '2.0.0',
        'timestamp': datetime.utcnow().isoformat()
    })

@app.route('/auth/register', methods=['POST'])
def register():
    data = request.get_json(force=True)
    username = data.get('username', '').strip()
    password = data.get('password', '').strip()
    fullName = data.get('fullName', username).strip()
    role = data.get('role', 'student').strip().lower()

    deviceId = data.get('deviceId', '').strip()
    deviceModel = data.get('deviceModel', 'Mobile Device').strip()

    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400

    if role not in ['student', 'organiser', 'admin']:
        role = 'student'

    hashed = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    try:
        with get_db() as conn:
            if deviceId:
                existing_device = conn.execute('SELECT username FROM users WHERE deviceId = ?', (deviceId,)).fetchone()
                if existing_device and existing_device['username'].lower() != username.lower():
                    return jsonify({'error': f"Hardware security violation: This phone is already bound to account '{existing_device['username']}'. Only 1 account per device is allowed!"}), 409

            cursor = conn.execute(
                'INSERT INTO users (username, fullName, password, role, deviceId, deviceModel, isApproved) VALUES (?, ?, ?, ?, ?, ?, 1)',
                (username, fullName, hashed, role, deviceId or None, deviceModel if deviceId else None)
            )
            conn.commit()
            return jsonify({'message': 'Account created successfully!', 'userId': cursor.lastrowid}), 201
    except sqlite3.IntegrityError:
        return jsonify({'error': 'Username already exists'}), 409
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/auth/login', methods=['POST'])
def login():
    data = request.get_json(force=True)
    username = data.get('username', '').strip()
    password = data.get('password', '').strip()

    with get_db() as conn:
        user = conn.execute('SELECT * FROM users WHERE username = ?', (username,)).fetchone()
        if not user or not bcrypt.checkpw(password.encode('utf-8'), user['password'].encode('utf-8')):
            return jsonify({'error': 'Invalid username or password'}), 401

        token = create_jwt(user['id'], user['role'], user['username'])
        return jsonify({
            'token': token,
            'userId': user['id'],
            'username': user['username'],
            'fullName': user['fullName'] or user['username'],
            'role': user['role'],
            'deviceId': user['deviceId'],
            'isApproved': bool(user['isApproved'])
        })

@app.route('/auth/me', methods=['GET'])
def get_me():
    curr = get_current_user()
    if not curr:
        return jsonify({'error': 'Unauthorized'}), 401
    with get_db() as conn:
        user = conn.execute('SELECT id, username, fullName, role, deviceId, deviceModel, isApproved FROM users WHERE id = ?', (curr['id'],)).fetchone()
        if not user:
            return jsonify({'error': 'User not found'}), 404
        return jsonify(dict(user))

# ================= DEVICE BINDING (ANTI-PROXY) =================

@app.route('/user/bind-device', methods=['PUT'])
def bind_device():
    curr = get_current_user()
    if not curr:
        return jsonify({'error': 'Unauthorized'}), 401

    data = request.get_json(force=True)
    device_id = data.get('deviceId', '').strip()
    device_model = data.get('deviceModel', 'Mobile Device')

    if not device_id:
        return jsonify({'error': 'deviceId required'}), 400

    with get_db() as conn:
        device_taken = conn.execute('SELECT username FROM users WHERE deviceId = ? AND id != ?', (device_id, curr['id'])).fetchone()
        if device_taken:
            return jsonify({'error': f"Hardware security violation: This phone is already bound to account '{device_taken['username']}'. Only 1 account per device is allowed!"}), 409

        existing = conn.execute('SELECT deviceId, isApproved FROM users WHERE id = ?', (curr['id'],)).fetchone()
        
        # If user has no device registered yet, auto-approve the first device!
        if not existing or not existing['deviceId']:
            conn.execute(
                'UPDATE users SET deviceId = ?, deviceModel = ?, isApproved = 1 WHERE id = ?',
                (device_id, device_model, curr['id'])
            )
            conn.commit()
            return jsonify({
                'message': 'Primary device bound successfully and approved!',
                'deviceId': device_id,
                'isApproved': True
            })
        elif existing['deviceId'] == device_id:
            # Same device, return current status
            return jsonify({
                'message': 'Device already bound.',
                'deviceId': device_id,
                'isApproved': bool(existing['isApproved'])
            })
        else:
            # Switching to a different device requires Organiser / Admin approval!
            conn.execute(
                'UPDATE users SET deviceId = ?, deviceModel = ?, isApproved = 0 WHERE id = ?',
                (device_id, device_model, curr['id'])
            )
            conn.commit()
            return jsonify({
                'message': 'New device detected. Device switch requires Organiser approval before attendance can be marked.',
                'deviceId': device_id,
                'isApproved': False
            })

@app.route('/admin/pending-approvals', methods=['GET'])
def pending_approvals():
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Organiser or Admin privileges required'}), 403

    with get_db() as conn:
        rows = conn.execute(
            'SELECT id, username, fullName, deviceId, deviceModel FROM users WHERE role = "student" AND isApproved = 0'
        ).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/admin/approve-device', methods=['PUT'])
def approve_device():
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Organiser or Admin privileges required'}), 403

    data = request.get_json(force=True)
    user_id = data.get('userId')
    approve = data.get('approve', True)

    with get_db() as conn:
        if approve:
            conn.execute('UPDATE users SET isApproved = 1 WHERE id = ?', (user_id,))
        else:
            # Reset device if rejected
            conn.execute('UPDATE users SET deviceId = NULL, isApproved = 1 WHERE id = ?', (user_id,))
        conn.commit()
        return jsonify({'message': f'Device {"approved" if approve else "rejected"} successfully.'})

# ================= MASTER ADMIN SUITE (USER MANAGEMENT, DEVICE LOCK & RECOVERY) =================

@app.route('/admin/stats', methods=['GET'])
def admin_stats():
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin or Organiser privileges required'}), 403

    with get_db() as conn:
        total_students = conn.execute("SELECT COUNT(*) as c FROM users WHERE role = 'student'").fetchone()['c']
        total_organisers = conn.execute("SELECT COUNT(*) as c FROM users WHERE role = 'organiser'").fetchone()['c']
        total_sessions = conn.execute("SELECT COUNT(*) as c FROM sessions").fetchone()['c']
        total_attendance = conn.execute("SELECT COUNT(*) as c FROM attendance").fetchone()['c']
        pending_approvals = conn.execute("SELECT COUNT(*) as c FROM users WHERE isApproved = 0 AND role = 'student'").fetchone()['c']
        return jsonify({
            'totalStudents': total_students,
            'totalOrganisers': total_organisers,
            'totalSessions': total_sessions,
            'totalAttendance': total_attendance,
            'pendingApprovals': pending_approvals
        })

@app.route('/admin/users', methods=['GET'])
def admin_get_users():
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin or Organiser privileges required'}), 403

    q = request.args.get('q', '').strip().lower()
    role_filter = request.args.get('role', '').strip().lower()

    with get_db() as conn:
        query = '''
            SELECT u.id, u.username, u.fullName, u.role, u.deviceId, u.deviceModel, u.isApproved, u.createdAt,
                   (SELECT COUNT(*) FROM attendance a WHERE a.studentId = u.id) as attendanceCount
            FROM users u
            WHERE 1=1
        '''
        params = []
        if role_filter in ['student', 'organiser', 'admin']:
            query += ' AND u.role = ?'
            params.append(role_filter)
        if q:
            query += ' AND (LOWER(u.username) LIKE ? OR LOWER(COALESCE(u.fullName, "")) LIKE ? OR LOWER(COALESCE(u.deviceId, "")) LIKE ?)'
            params.extend([f'%{q}%', f'%{q}%', f'%{q}%'])
        query += ' ORDER BY u.id DESC'
        rows = conn.execute(query, params).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/admin/users/<int:user_id>/reset-password', methods=['POST'])
def admin_reset_password(user_id):
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin privileges required'}), 403

    data = request.get_json(force=True) if request.data else {}
    new_password = str(data.get('newPassword', '')).strip()
    if not new_password or len(new_password) < 4:
        return jsonify({'error': 'New password must be at least 4 characters long'}), 400

    with get_db() as conn:
        user = conn.execute('SELECT id, username, role FROM users WHERE id = ?', (user_id,)) .fetchone()
        if not user:
            return jsonify({'error': 'User not found'}), 404
        if user['role'] in ['admin', 'organiser'] and curr['role'] != 'admin':
            return jsonify({'error': 'Only Super Admin can reset organiser/admin passwords'}), 403

        hashed = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
        conn.execute('UPDATE users SET password = ? WHERE id = ?', (hashed, user_id))
        conn.commit()
        return jsonify({'success': True, 'message': f"Password for user '{user['username']}' was successfully reset!"})

@app.route('/admin/users/<int:user_id>/reset-device', methods=['POST'])
def admin_reset_device(user_id):
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin privileges required'}), 403

    with get_db() as conn:
        user = conn.execute('SELECT id, username, deviceId FROM users WHERE id = ?', (user_id,)).fetchone()
        if not user:
            return jsonify({'error': 'User not found'}), 404

        old_device = user['deviceId'] or 'None'
        conn.execute('UPDATE users SET deviceId = NULL, deviceModel = NULL, isApproved = 1 WHERE id = ?', (user_id,))
        conn.commit()
        return jsonify({
            'success': True,
            'message': f"Hardware device lock for '{user['username']}' has been reset! The student can now bind their new phone on next login.",
            'previousDeviceId': old_device
        })

@app.route('/admin/users/<int:user_id>', methods=['DELETE'])
def admin_delete_user(user_id):
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin privileges required'}), 403

    with get_db() as conn:
        user = conn.execute('SELECT id, username, role FROM users WHERE id = ?', (user_id,)).fetchone()
        if not user:
            return jsonify({'error': 'User not found'}), 404
        if user['id'] == curr['id']:
            return jsonify({'error': 'You cannot delete your own active administrator account!'}), 400
        if user['role'] == 'admin' and curr['role'] != 'admin':
            return jsonify({'error': 'Cannot delete an administrator'}), 403

        # Clean associated records
        conn.execute('DELETE FROM attendance WHERE studentId = ?', (user_id,))
        conn.execute('DELETE FROM sessions WHERE organiserId = ?', (user_id,))
        conn.execute('DELETE FROM users WHERE id = ?', (user_id,))
        conn.commit()
        return jsonify({
            'success': True,
            'message': f"User '{user['username']}' ({user['role']}) and all associated records have been permanently removed."
        })

@app.route('/admin/export-all', methods=['GET'])
def admin_export_all():
    curr = get_current_user()
    if not curr or curr.get('role') not in ['organiser', 'admin']:
        return jsonify({'error': 'Admin privileges required'}), 403

    with get_db() as conn:
        rows = conn.execute('''
            SELECT s.id as sessionId, s.title as sessionTitle, s.createdAt as sessionDate,
                   u.username, u.fullName, a.status, a.timestamp as markedAt, a.rssi, a.deviceId
            FROM attendance a
            JOIN sessions s ON a.sessionId = s.id
            JOIN users u ON a.studentId = u.id
            ORDER BY s.id DESC, u.username ASC
        ''').fetchall()

        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(['Session ID', 'Session Title', 'Session Date', 'Roll / Username', 'Student Name', 'Status', 'Marked At', 'RSSI (dBm)', 'Device ID'])
        for r in rows:
            writer.writerow([r['sessionId'], r['sessionTitle'], r['sessionDate'], r['username'], r['fullName'], r['status'], r['markedAt'], r['rssi'], r['deviceId']])

        csv_content = output.getvalue()
        filename = f"all_attendance_records_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
        return Response(
            csv_content,
            mimetype="text/csv",
            headers={"Content-disposition": f"attachment; filename={filename}"}
        )

ADMIN_DASHBOARD_HTML = '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ProxyProof — Super Admin Control Portal</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0b0c16;
      --card: #151628;
      --card-border: #242645;
      --primary: #6c63ff;
      --primary-hover: #574fd6;
      --cyan: #00d2ff;
      --green: #10b981;
      --red: #ef4444;
      --amber: #f59e0b;
      --text: #f8fafc;
      --muted: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: var(--bg); color: var(--text); font-family: 'Poppins', sans-serif; min-height: 100vh; display: flex; flex-direction: column; }
    header { background: #111222; border-bottom: 1px solid var(--card-border); padding: 16px 28px; display: flex; justify-content: space-between; align-items: center; }
    .logo { display: flex; align-items: center; gap: 12px; font-size: 19px; font-weight: 700; }
    .logo-badge { background: linear-gradient(135deg, var(--primary), var(--cyan)); padding: 4px 10px; border-radius: 8px; font-size: 12px; font-weight: 700; color: #fff; }
    .user-pill { display: flex; align-items: center; gap: 14px; font-size: 13px; }
    .btn { background: var(--primary); color: #fff; border: 0; padding: 8px 16px; border-radius: 8px; font-weight: 600; font-size: 13px; cursor: pointer; transition: all 0.2s; }
    .btn:hover { background: var(--primary-hover); transform: translateY(-1px); }
    .btn-outline { background: transparent; border: 1px solid var(--card-border); color: var(--text); }
    .btn-outline:hover { background: var(--card-border); }
    .btn-danger { background: var(--red); color: white; }
    .btn-danger:hover { background: #dc2626; }
    .btn-cyan { background: var(--cyan); color: #000; font-weight: 700; }
    .btn-cyan:hover { background: #00b4db; }
    .btn-sm { padding: 5px 10px; font-size: 11px; border-radius: 6px; }
    main { max-width: 1320px; width: 100%; margin: 0 auto; padding: 26px 20px; flex: 1; }
    .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .stat-card { background: var(--card); border: 1px solid var(--card-border); border-radius: 12px; padding: 18px; display: flex; flex-direction: column; gap: 5px; }
    .stat-title { font-size: 11px; color: var(--muted); font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
    .stat-value { font-size: 30px; font-weight: 800; color: #fff; }
    .panel { background: var(--card); border: 1px solid var(--card-border); border-radius: 14px; padding: 22px; box-shadow: 0 10px 30px rgba(0,0,0,0.3); }
    .panel-header { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 14px; margin-bottom: 18px; }
    .search-box { display: flex; align-items: center; gap: 10px; flex: 1; max-width: 400px; }
    .search-input { width: 100%; background: #0f101d; border: 1px solid var(--card-border); color: var(--text); padding: 9px 13px; border-radius: 8px; outline: none; font-size: 13px; }
    .search-input:focus { border-color: var(--primary); }
    .filter-tabs { display: flex; gap: 8px; }
    .tab { background: #0f101d; border: 1px solid var(--card-border); color: var(--muted); padding: 6px 13px; border-radius: 20px; font-size: 11px; cursor: pointer; font-weight: 600; }
    .tab.active { background: var(--primary); color: white; border-color: var(--primary); }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; text-align: left; font-size: 12.5px; }
    th { background: #0f101d; color: var(--muted); font-size: 11px; text-transform: uppercase; padding: 12px 14px; border-bottom: 1px solid var(--card-border); font-weight: 700; }
    td { padding: 12px 14px; border-bottom: 1px solid var(--card-border); vertical-align: middle; }
    tr:hover td { background: rgba(108, 99, 255, 0.04); }
    .badge { display: inline-block; padding: 3px 8px; border-radius: 6px; font-size: 10px; font-weight: 700; text-transform: uppercase; }
    .badge-student { background: rgba(0, 210, 255, 0.15); color: var(--cyan); }
    .badge-organiser { background: rgba(108, 99, 255, 0.2); color: #a5a0ff; }
    .badge-admin { background: rgba(245, 158, 11, 0.2); color: var(--amber); }
    .badge-ok { background: rgba(16, 185, 129, 0.15); color: var(--green); }
    .badge-warn { background: rgba(239, 68, 68, 0.15); color: var(--red); }
    .action-group { display: flex; gap: 6px; flex-wrap: wrap; }
    .modal-backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(4px); display: none; place-items: center; z-index: 100; padding: 20px; }
    .modal-backdrop.open { display: grid; }
    .modal { background: var(--card); border: 1px solid var(--card-border); border-radius: 14px; max-width: 440px; width: 100%; padding: 24px; box-shadow: 0 20px 40px rgba(0,0,0,0.5); }
    .modal-title { font-size: 17px; font-weight: 700; margin-bottom: 8px; }
    .modal-desc { font-size: 12.5px; color: var(--muted); margin-bottom: 16px; line-height: 1.5; }
    .modal-input { width: 100%; background: #0f101d; border: 1px solid var(--card-border); color: white; padding: 10px 12px; border-radius: 8px; outline: none; font-size: 13px; margin-bottom: 16px; }
    .modal-footer { display: flex; justify-content: flex-end; gap: 10px; }
    .login-overlay { position: fixed; inset: 0; background: var(--bg); display: flex; place-items: center; justify-content: center; z-index: 90; padding: 20px; }
    .login-box { background: var(--card); border: 1px solid var(--card-border); border-radius: 16px; max-width: 380px; width: 100%; padding: 30px; text-align: center; }
  </style>
</head>
<body>
  <div id="loginOverlay" class="login-overlay">
    <div class="login-box">
      <div style="font-size: 40px; margin-bottom: 10px;">🛡️</div>
      <h2 style="font-size: 20px; margin-bottom: 6px;">ProxyProof Admin</h2>
      <p style="font-size: 12px; color: var(--muted); margin-bottom: 20px;">Enter Super Admin credentials to access the system control portal.</p>
      <input type="text" id="loginUser" class="modal-input" placeholder="Admin username (default: admin)" value="admin">
      <input type="password" id="loginPass" class="modal-input" placeholder="Password (default: admin123)" value="admin123">
      <button class="btn" style="width: 100%; padding: 12px;" onclick="handleLogin()">Log In to Portal →</button>
      <div id="loginErr" style="color: var(--red); font-size: 12px; margin-top: 12px;"></div>
    </div>
  </div>

  <header>
    <div class="logo">
      <span>🛡️ ProxyProof</span>
      <span class="logo-badge">Super Admin Portal</span>
    </div>
    <div class="user-pill">
      <span id="adminName" style="color: var(--cyan); font-weight: 600;">System Administrator</span>
      <a href="/admin/export-all" target="_blank" class="btn btn-outline btn-sm">Export All CSV ↗</a>
      <button class="btn btn-outline btn-sm" onclick="handleLogout()">Logout</button>
    </div>
  </header>

  <main>
    <div class="stats-grid">
      <div class="stat-card">
        <span class="stat-title">Total Students</span>
        <span class="stat-value" id="statStudents">—</span>
      </div>
      <div class="stat-card">
        <span class="stat-title">Faculty / Organisers</span>
        <span class="stat-value" id="statOrganisers">—</span>
      </div>
      <div class="stat-card">
        <span class="stat-title">Total Sessions</span>
        <span class="stat-value" id="statSessions">—</span>
      </div>
      <div class="stat-card">
        <span class="stat-title">Attendance Verified</span>
        <span class="stat-value" id="statAttendance" style="color: var(--cyan);">—</span>
      </div>
      <div class="stat-card">
        <span class="stat-title">Pending Device Approvals</span>
        <span class="stat-value" id="statApprovals" style="color: var(--amber);">—</span>
      </div>
    </div>

    <div class="panel">
      <div class="panel-header">
        <div class="search-box">
          <input type="text" id="searchInput" class="search-input" placeholder="Search by roll number, name, or device ID…" oninput="filterUsers()">
        </div>
        <div class="filter-tabs">
          <button class="tab active" onclick="setRoleFilter('', this)">All Users</button>
          <button class="tab" onclick="setRoleFilter('student', this)">Students</button>
          <button class="tab" onclick="setRoleFilter('organiser', this)">Faculty</button>
          <button class="tab" onclick="loadDashboard()">↻ Refresh</button>
        </div>
      </div>

      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Roll / Username</th>
              <th>Full Name</th>
              <th>Role</th>
              <th>Device Bound</th>
              <th>Status</th>
              <th>Attendance</th>
              <th style="text-align: right;">Administrative Actions</th>
            </tr>
          </thead>
          <tbody id="userTableBody">
            <tr><td colspan="8" style="text-align: center; color: var(--muted); padding: 30px;">Loading users…</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </main>

  <!-- Reset Password Modal -->
  <div id="resetPwdModal" class="modal-backdrop">
    <div class="modal">
      <div class="modal-title">🔑 Reset User Password</div>
      <div class="modal-desc" id="resetPwdDesc">Enter the new password for this user. They will immediately be able to log in with this new password.</div>
      <input type="password" id="newPasswordInput" class="modal-input" placeholder="Enter new password (min 4 chars)">
      <div class="modal-footer">
        <button class="btn btn-outline" onclick="closeModal('resetPwdModal')">Cancel</button>
        <button class="btn" onclick="submitPasswordReset()">Save New Password</button>
      </div>
    </div>
  </div>

  <script>
    let currentToken = localStorage.getItem('proxyproof_admin_token') || '';
    let allUsers = [];
    let activeRoleFilter = '';
    let selectedUserId = null;

    async function checkAuth() {
      if (!currentToken) {
        document.getElementById('loginOverlay').style.display = 'flex';
        return;
      }
      try {
        const res = await fetch('/auth/me', { headers: { 'Authorization': 'Bearer ' + currentToken } });
        if (!res.ok) throw new Error();
        const data = await res.json();
        if (data.role !== 'admin' && data.role !== 'organiser') throw new Error('Not admin');
        document.getElementById('loginOverlay').style.display = 'none';
        document.getElementById('adminName').innerText = data.fullName || data.username;
        loadDashboard();
      } catch (_) {
        currentToken = '';
        localStorage.removeItem('proxyproof_admin_token');
        document.getElementById('loginOverlay').style.display = 'flex';
      }
    }

    async function handleLogin() {
      const u = document.getElementById('loginUser').value.trim();
      const p = document.getElementById('loginPass').value.trim();
      const errBox = document.getElementById('loginErr');
      errBox.innerText = '';
      try {
        const res = await fetch('/auth/login', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: u, password: p })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Login failed');
        if (data.role !== 'admin' && data.role !== 'organiser') throw new Error('Account does not have admin privileges');
        currentToken = data.token;
        localStorage.setItem('proxyproof_admin_token', currentToken);
        document.getElementById('loginOverlay').style.display = 'none';
        document.getElementById('adminName').innerText = data.fullName || data.username;
        loadDashboard();
      } catch (err) {
        errBox.innerText = err.message;
      }
    }

    function handleLogout() {
      localStorage.removeItem('proxyproof_admin_token');
      currentToken = '';
      location.reload();
    }

    async function loadDashboard() {
      try {
        const [statsRes, usersRes] = await Promise.all([
          fetch('/admin/stats', { headers: { 'Authorization': 'Bearer ' + currentToken } }),
          fetch('/admin/users', { headers: { 'Authorization': 'Bearer ' + currentToken } })
        ]);
        if (statsRes.ok) {
          const stats = await statsRes.json();
          document.getElementById('statStudents').innerText = stats.totalStudents;
          document.getElementById('statOrganisers').innerText = stats.totalOrganisers;
          document.getElementById('statSessions').innerText = stats.totalSessions;
          document.getElementById('statAttendance').innerText = stats.totalAttendance;
          document.getElementById('statApprovals').innerText = stats.pendingApprovals;
        }
        if (usersRes.ok) {
          allUsers = await usersRes.json();
          renderUsers();
        }
      } catch (e) {
        console.error(e);
      }
    }

    function setRoleFilter(role, el) {
      activeRoleFilter = role;
      document.querySelectorAll('.filter-tabs .tab').forEach(t => t.classList.remove('active'));
      el.classList.add('active');
      renderUsers();
    }

    function filterUsers() {
      renderUsers();
    }

    function renderUsers() {
      const query = document.getElementById('searchInput').value.trim().toLowerCase();
      const tbody = document.getElementById('userTableBody');
      const filtered = allUsers.filter(u => {
        if (activeRoleFilter && u.role !== activeRoleFilter) return false;
        if (query) {
          const matchesUser = (u.username || '').toLowerCase().includes(query);
          const matchesName = (u.fullName || '').toLowerCase().includes(query);
          const matchesDevice = (u.deviceId || '').toLowerCase().includes(query);
          return matchesUser || matchesName || matchesDevice;
        }
        return true;
      });

      if (!filtered.length) {
        tbody.innerHTML = '<tr><td colspan="8" style="text-align: center; color: var(--muted); padding: 30px;">No matching users found.</td></tr>';
        return;
      }

      tbody.innerHTML = filtered.map(u => {
        const roleBadge = u.role === 'admin' ? '<span class="badge badge-admin">Admin</span>' : (u.role === 'organiser' ? '<span class="badge badge-organiser">Faculty</span>' : '<span class="badge badge-student">Student</span>');
        const deviceStatus = !u.deviceId ? '<span class="badge" style="background:#2a2b3d;color:#94a3b8;">Unbound</span>' : (u.isApproved ? '<span class="badge badge-ok">Bound ✓</span>' : '<span class="badge badge-warn">Pending Approval</span>');
        const deviceText = u.deviceId ? `<small title="${u.deviceId}" style="color:var(--muted);">${u.deviceModel || 'Phone'}<br/><code style="font-size:10px;">${u.deviceId.slice(0, 14)}…</code></small>` : '<small style="color:#64748b;">No phone registered</small>';

        return `
          <tr>
            <td><code style="color:var(--muted);">#${u.id}</code></td>
            <td><strong>${u.username}</strong></td>
            <td>${u.fullName || u.username}</td>
            <td>${roleBadge}</td>
            <td>${deviceText}</td>
            <td>${deviceStatus}</td>
            <td><strong>${u.attendanceCount || 0}</strong></td>
            <td style="text-align: right;">
              <div class="action-group" style="justify-content: flex-end;">
                <button class="btn btn-outline btn-sm" onclick="promptResetPassword(${u.id}, '${u.username}')" title="Reset user password">🔑 Password</button>
                <button class="btn btn-outline btn-sm" onclick="resetDevice(${u.id}, '${u.username}')" title="Unbind phone lock">📱 Unbind Phone</button>
                ${!u.isApproved ? `<button class="btn btn-cyan btn-sm" onclick="approveDevice(${u.id}, true)">Approve Device</button>` : ''}
                ${u.role !== 'admin' ? `<button class="btn btn-danger btn-sm" onclick="deleteUser(${u.id}, '${u.username}')" title="Permanently delete user">🗑️</button>` : ''}
              </div>
            </td>
          </tr>
        `;
      }).join('');
    }

    function promptResetPassword(userId, username) {
      selectedUserId = userId;
      document.getElementById('resetPwdDesc').innerText = `Set a new password for account "${username}".`;
      document.getElementById('newPasswordInput').value = '';
      document.getElementById('resetPwdModal').classList.add('open');
      document.getElementById('newPasswordInput').focus();
    }

    async function submitPasswordReset() {
      const pwd = document.getElementById('newPasswordInput').value.trim();
      if (!pwd || pwd.length < 4) {
        alert('Password must be at least 4 characters long.');
        return;
      }
      try {
        const res = await fetch(`/admin/users/${selectedUserId}/reset-password`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + currentToken
          },
          body: JSON.stringify({ newPassword: pwd })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Failed to reset password');
        alert(data.message);
        closeModal('resetPwdModal');
      } catch (err) {
        alert(err.message);
      }
    }

    async function resetDevice(userId, username) {
      if (!confirm(`Are you sure you want to UNBIND the phone for "${username}"?\\n\\nThis will remove the hardware lock and allow the student to bind their new phone when they log in next.`)) return;
      try {
        const res = await fetch(`/admin/users/${userId}/reset-device`, {
          method: 'POST',
          headers: { 'Authorization': 'Bearer ' + currentToken }
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Failed to reset device');
        alert(data.message);
        loadDashboard();
      } catch (err) {
        alert(err.message);
      }
    }

    async function approveDevice(userId, approve) {
      try {
        const res = await fetch('/admin/approve-device', {
          method: 'PUT',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ' + currentToken
          },
          body: JSON.stringify({ userId, approve })
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Approval failed');
        loadDashboard();
      } catch (err) {
        alert(err.message);
      }
    }

    async function deleteUser(userId, username) {
      if (!confirm(`⚠️ DANGER: Are you sure you want to permanently delete user "${username}"?\\n\\nAll their attendance history and device records will be wiped. This action cannot be undone!`)) return;
      try {
        const res = await fetch(`/admin/users/${userId}`, {
          method: 'DELETE',
          headers: { 'Authorization': 'Bearer ' + currentToken }
        });
        const data = await res.json();
        if (!res.ok) throw new Error(data.error || 'Failed to delete user');
        alert(data.message);
        loadDashboard();
      } catch (err) {
        alert(err.message);
      }
    }

    function closeModal(id) {
      document.getElementById(id).classList.remove('open');
    }

    checkAuth();
  </script>
</body>
</html>
'''

@app.route('/admin', methods=['GET'])
def admin_portal():
    return Response(ADMIN_DASHBOARD_HTML, mimetype='text/html')


# ================= SESSION MANAGEMENT =================

def generate_token():
    return str(random.randint(100000, 999999))

@app.route('/session/start', methods=['POST'])
def start_session():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    data = request.get_json(force=True) if request.data else {}
    title = data.get('title', 'Attendance Session')
    duration = int(data.get('durationMinutes', 5))

    initial_token = generate_token()
    expires_at = (datetime.utcnow() + timedelta(minutes=duration)).isoformat()

    with get_db() as conn:
        # Mark all previous sessions of this organiser as inactive
        conn.execute('UPDATE sessions SET isActive = 0 WHERE organiserId = ?', (curr['id'],))
        
        cursor = conn.execute(
            '''INSERT INTO sessions (organiserId, title, durationMinutes, currentToken, recentTokens, isActive, expiresAt)
               VALUES (?, ?, ?, ?, ?, 1, ?)''',
            (curr['id'], title, duration, initial_token, initial_token, expires_at)
        )
        conn.commit()
        session_id = cursor.lastrowid

        return jsonify({
            'sessionId': session_id,
            'title': title,
            'durationMinutes': duration,
            'currentToken': initial_token,
            'expiresAt': expires_at,
            'isActive': True
        })

@app.route('/session/rotate-token', methods=['PUT'])
def rotate_token():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    data = request.get_json(force=True)
    session_id = data.get('sessionId')
    new_token = str(data.get('newToken') or generate_token())

    with get_db() as conn:
        session = conn.execute('SELECT * FROM sessions WHERE id = ? AND isActive = 1', (session_id,)).fetchone()
        if not session:
            return jsonify({'error': 'Active session not found'}), 404

        # Keep a rolling list of last 3 tokens for network jitter tolerance (15 seconds)
        recent = session['recentTokens'].split(',') if session['recentTokens'] else []
        recent.insert(0, session['currentToken'])
        recent = recent[:4] # keep last 4 tokens
        recent_str = ','.join(recent)

        conn.execute('UPDATE sessions SET currentToken = ?, recentTokens = ? WHERE id = ?', (new_token, recent_str, session_id))
        conn.commit()
        return jsonify({'success': True, 'newToken': new_token})

@app.route('/session/close', methods=['POST'])
def close_session():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    data = request.get_json(force=True)
    session_id = data.get('sessionId')

    with get_db() as conn:
        conn.execute('UPDATE sessions SET isActive = 0 WHERE id = ?', (session_id,))
        conn.commit()
        return jsonify({'message': 'Session closed successfully'})

@app.route('/session/active', methods=['GET'])
def get_active_session():
    with get_db() as conn:
        session = conn.execute(
            '''SELECT s.*, u.username as organiserName 
               FROM sessions s 
               JOIN users u ON s.organiserId = u.id 
               WHERE s.isActive = 1 
               ORDER BY s.id DESC LIMIT 1'''
        ).fetchone()

        if not session:
            return jsonify({'active': False})

        # Check if expired
        expires = datetime.fromisoformat(session['expiresAt'])
        if datetime.utcnow() > expires:
            conn.execute('UPDATE sessions SET isActive = 0 WHERE id = ?', (session['id'],))
            conn.commit()
            return jsonify({'active': False, 'message': 'Session has expired'})

        return jsonify({
            'active': True,
            'sessionId': session['id'],
            'title': session['title'],
            'organiserName': session['organiserName'],
            'currentToken': session['currentToken'],
            'expiresAt': session['expiresAt'],
            'durationMinutes': session['durationMinutes']
        })

# ================= ATTENDANCE MARKING & ANTI-PROXY =================

@app.route('/attendance/mark', methods=['POST'])
def mark_attendance():
    curr = get_current_user()
    if not curr:
        return jsonify({'error': 'Unauthorized'}), 401

    data = request.get_json(force=True)
    session_id = data.get('sessionId')
    token_received = str(data.get('token', '')).strip()
    rssi = data.get('rssi', -70)
    device_id = data.get('deviceId', '').strip()

    if not session_id or not token_received:
        return jsonify({'error': 'Session ID and token are required'}), 400

    with get_db() as conn:
        # 1. Fetch Student User
        user = conn.execute('SELECT * FROM users WHERE id = ?', (curr['id'],)).fetchone()
        if not user or user['role'] != 'student':
            return jsonify({'error': 'Only students can mark attendance'}), 403

        # 2. Check Device Binding & Approval (Core Anti-Proxy Rule #1)
        if not user['deviceId']:
            return jsonify({'error': 'Your device is not registered. Please bind your device first.'}), 403
        if user['deviceId'] != device_id:
            return jsonify({'error': 'Hardware device mismatch! Attendance can only be marked from your registered device.'}), 403
        if not user['isApproved']:
            return jsonify({'error': 'Your device registration is pending approval by the organiser.'}), 403

        # 3. Check Session Active & Not Expired
        session = conn.execute('SELECT * FROM sessions WHERE id = ? AND isActive = 1', (session_id,)).fetchone()
        if not session:
            return jsonify({'error': 'Session is not active or has ended'}), 400

        expires = datetime.fromisoformat(session['expiresAt'])
        if datetime.utcnow() > expires:
            conn.execute('UPDATE sessions SET isActive = 0 WHERE id = ?', (session_id,))
            conn.commit()
            return jsonify({'error': 'Session time has expired'}), 400

        # 4. Anti-Proxy: Rotating Token Validation (Core Anti-Proxy Rule #4)
        valid_tokens = [session['currentToken']]
        if session['recentTokens']:
            valid_tokens.extend(session['recentTokens'].split(','))

        if token_received not in valid_tokens:
            return jsonify({'error': 'Expired or invalid security token! Codes rotate every few seconds.'}), 400

        # 5. Anti-Proxy: Proximity RSSI Threshold (Physical Presence Check)
        # RSSI is negative dBm. Signals below -85 dBm are considered outside the room
        try:
            rssi_val = int(rssi)
        except Exception:
            rssi_val = -70

        if rssi_val < -85:
            return jsonify({'error': f'Proximity check failed (RSSI {rssi_val} dBm). You must be physically inside the room.'}), 400

        # 6. Anti-Proxy: One device = One student per session (Core Anti-Proxy Rule #4)
        same_device = conn.execute(
            'SELECT * FROM attendance WHERE sessionId = ? AND deviceId = ?',
            (session_id, device_id)
        ).fetchone()
        if same_device and same_device['studentId'] != user['id']:
            return jsonify({'error': 'Proxy alert! This physical device has already marked attendance for another student.'}), 409

        # 7. Check if already marked
        already_marked = conn.execute(
            'SELECT * FROM attendance WHERE sessionId = ? AND studentId = ?',
            (session_id, user['id'])
        ).fetchone()
        if already_marked:
            return jsonify({'message': 'Attendance already marked for this session!', 'alreadyPresent': True})

        # 8. Mark Attendance!
        conn.execute(
            'INSERT INTO attendance (sessionId, studentId, rssi, deviceId, status) VALUES (?, ?, ?, ?, "Present")',
            (session_id, user['id'], rssi_val, device_id)
        )
        conn.commit()

        return jsonify({
            'success': True,
            'message': 'Attendance successfully verified and marked!',
            'username': user['username'],
            'rssi': rssi_val,
            'time': datetime.now().strftime('%H:%M:%S')
        })

# ================= LIVE DASHBOARD & ACTIONS =================

@app.route('/attendance/dashboard/<int:session_id>', methods=['GET'])
def get_dashboard(session_id):
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    with get_db() as conn:
        rows = conn.execute(
            '''SELECT a.id as attendanceId, a.timestamp, a.rssi, a.deviceId, a.status,
                      u.id as studentId, u.username, u.fullName
               FROM attendance a
               JOIN users u ON a.studentId = u.id
               WHERE a.sessionId = ?
               ORDER BY a.id DESC''',
            (session_id,)
        ).fetchall()

        return jsonify([
            {
                'attendanceId': r['attendanceId'],
                'studentId': {
                    'id': r['studentId'],
                    'username': r['username'],
                    'fullName': r['fullName'] or r['username']
                },
                'timestamp': r['timestamp'],
                'rssi': r['rssi'],
                'deviceId': r['deviceId'],
                'status': r['status']
            }
            for r in rows
        ])

@app.route('/attendance/manual-add', methods=['POST'])
def manual_add():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    data = request.get_json(force=True)
    session_id = data.get('sessionId')
    username = data.get('username', '').strip()

    with get_db() as conn:
        user = conn.execute('SELECT id, username FROM users WHERE username = ? AND role = "student"', (username,)).fetchone()
        if not user:
            return jsonify({'error': f'Student "{username}" not found'}), 404

        existing = conn.execute('SELECT * FROM attendance WHERE sessionId = ? AND studentId = ?', (session_id, user['id'])).fetchone()
        if existing:
            return jsonify({'error': 'Student is already marked present'}), 400

        conn.execute(
            'INSERT INTO attendance (sessionId, studentId, rssi, deviceId, status) VALUES (?, ?, ?, ?, "Manual")',
            (session_id, user['id'], 0, 'Organiser Override')
        )
        conn.commit()
        return jsonify({'message': f'Student {username} marked present manually!'})

@app.route('/attendance/manual-remove', methods=['POST'])
def manual_remove():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    data = request.get_json(force=True)
    session_id = data.get('sessionId')
    student_id = data.get('studentId')

    with get_db() as conn:
        conn.execute('DELETE FROM attendance WHERE sessionId = ? AND studentId = ?', (session_id, student_id))
        conn.commit()
        return jsonify({'message': 'Attendance record removed'})

# ================= HISTORY & CSV EXPORT =================

@app.route('/attendance/history', methods=['GET'])
def attendance_history():
    curr = get_current_user()
    if not curr:
        return jsonify({'error': 'Unauthorized'}), 401

    with get_db() as conn:
        if curr['role'] == 'student':
            # Total completed or active sessions
            total_sessions = conn.execute('SELECT COUNT(*) as count FROM sessions').fetchone()['count']
            
            # Sessions student attended
            attended = conn.execute(
                '''SELECT a.timestamp, a.rssi, a.status, s.id as sessionId, s.title, s.createdAt
                   FROM attendance a
                   JOIN sessions s ON a.sessionId = s.id
                   WHERE a.studentId = ?
                   ORDER BY s.id DESC''',
                (curr['id'],)
            ).fetchall()

            attended_count = len(attended)
            percentage = round((attended_count / total_sessions * 100), 1) if total_sessions > 0 else 0.0

            return jsonify({
                'totalSessions': total_sessions,
                'attendedSessions': attended_count,
                'percentage': percentage,
                'records': [dict(r) for r in attended]
            })
        else:
            # Organiser view: list all sessions with count
            sessions = conn.execute(
                '''SELECT s.*, COUNT(a.id) as presentCount
                   FROM sessions s
                   LEFT JOIN attendance a ON s.id = a.sessionId
                   WHERE s.organiserId = ?
                   GROUP BY s.id
                   ORDER BY s.id DESC''',
                (curr['id'],)
            ).fetchall()
            return jsonify({'sessions': [dict(s) for s in sessions]})

@app.route('/attendance/export/<int:session_id>', methods=['GET'])
def export_csv(session_id):
    with get_db() as conn:
        session = conn.execute('SELECT * FROM sessions WHERE id = ?', (session_id,)).fetchone()
        if not session:
            return jsonify({'error': 'Session not found'}), 404

        rows = conn.execute(
            '''SELECT u.username, u.fullName, a.status, a.timestamp, a.rssi, a.deviceId
               FROM attendance a
               JOIN users u ON a.studentId = u.id
               WHERE a.sessionId = ?
               ORDER BY u.username ASC''',
            (session_id,)
        ).fetchall()

        output = io.StringIO()
        writer = csv.writer(output)
        writer.writerow(['Roll/Username', 'Full Name', 'Status', 'Marked At', 'Signal (dBm)', 'Device ID'])

        for r in rows:
            writer.writerow([r['username'], r['fullName'], r['status'], r['timestamp'], r['rssi'], r['deviceId']])

        csv_content = output.getvalue()
        filename = f"attendance_session_{session_id}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

        return Response(
            csv_content,
            mimetype="text/csv",
            headers={"Content-disposition": f"attachment; filename={filename}"}
        )

@app.route('/students', methods=['GET'])
def get_all_students():
    with get_db() as conn:
        students = conn.execute('SELECT id, username, fullName, deviceId, isApproved FROM users WHERE role = "student"').fetchall()
        return jsonify([dict(s) for s in students])

if __name__ == '__main__':
    port = int(os.environ.get("PORT", 5050))
    print('=' * 60)
    print('  🛡️  PROXYPROOF HIGH-SECURITY ATTENDANCE SERVER')
    print(f'  🚀  Running on 0.0.0.0:{port}')
    print('=' * 60)
    app.run(host='0.0.0.0', port=port, debug=False)
