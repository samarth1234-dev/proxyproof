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
                role TEXT NOT NULL, -- 'student' or 'organiser'
                deviceId TEXT,
                deviceModel TEXT,
                isApproved INTEGER DEFAULT 1,
                createdAt DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        ''')
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

    if not username or not password:
        return jsonify({'error': 'Username and password required'}), 400

    if role not in ['student', 'organiser']:
        role = 'student'

    hashed = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt()).decode('utf-8')
    try:
        with get_db() as conn:
            cursor = conn.execute(
                'INSERT INTO users (username, fullName, password, role, isApproved) VALUES (?, ?, ?, ?, 1)',
                (username, fullName, hashed, role)
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
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

    with get_db() as conn:
        rows = conn.execute(
            'SELECT id, username, fullName, deviceId, deviceModel FROM users WHERE role = "student" AND isApproved = 0'
        ).fetchall()
        return jsonify([dict(r) for r in rows])

@app.route('/admin/approve-device', methods=['PUT'])
def approve_device():
    curr = get_current_user()
    if not curr or curr.get('role') != 'organiser':
        return jsonify({'error': 'Organiser privileges required'}), 403

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
