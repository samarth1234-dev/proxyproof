const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const fs = require('fs');
const path = require('path');

const app = express();
app.use(express.json());
app.use(cors());

const PORT = process.env.PORT || 5050;
const JWT_SECRET = process.env.JWT_SECRET || 'proxyproof-super-secret-key-2026';
const DB_FILE = path.join(__dirname, 'proxyproof_node.json');

// Bulletproof persistent JSON store for zero native-addon ABI friction
let db = {
  users: [],
  sessions: [],
  attendance: []
};

if (fs.existsSync(DB_FILE)) {
  try {
    db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
  } catch (e) {
    console.error('Failed reading DB file, initializing fresh store:', e);
  }
}

function saveDb() {
  try {
    fs.writeFileSync(DB_FILE, JSON.stringify(db, null, 2), 'utf8');
  } catch (e) {
    console.error('Failed saving DB file:', e);
  }
}

function authMiddleware(req, res, next) {
  const authHeader = req.headers['authorization'];
  if (!authHeader) return res.status(401).json({ error: 'Unauthorized: No token provided' });
  const token = authHeader.replace('Bearer ', '').trim();
  jwt.verify(token, JWT_SECRET, (err, decoded) => {
    if (err) return res.status(401).json({ error: 'Unauthorized: Invalid token' });
    req.user = decoded;
    next();
  });
}

app.get('/', (req, res) => {
  res.json({
    status: 'online',
    app: 'ProxyProof Node API',
    version: '2.0.0',
    timestamp: new Date().toISOString()
  });
});

// AUTH
app.post('/auth/register', async (req, res) => {
  const { username, password, fullName, role } = req.body;
  if (!username || !password) return res.status(400).json({ error: 'Username and password required' });
  const existing = db.users.find(u => u.username.toLowerCase() === username.toLowerCase());
  if (existing) return res.status(409).json({ error: 'Username already exists' });

  const hashedPassword = await bcrypt.hash(password, 10);
  const newUser = {
    id: db.users.length + 1,
    username: username.trim(),
    fullName: fullName ? fullName.trim() : username.trim(),
    password: hashedPassword,
    role: (role && role.toLowerCase() === 'organiser') ? 'organiser' : 'student',
    deviceId: null,
    deviceModel: null,
    isApproved: true,
    createdAt: new Date().toISOString()
  };
  db.users.push(newUser);
  saveDb();
  res.status(201).json({ message: 'Account created successfully!', userId: newUser.id });
});

app.post('/auth/login', async (req, res) => {
  const { username, password } = req.body;
  const user = db.users.find(u => u.username.toLowerCase() === (username || '').toLowerCase().trim());
  if (!user || !(await bcrypt.compare(password, user.password))) {
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  const token = jwt.sign({ id: user.id, role: user.role, username: user.username }, JWT_SECRET, { expiresIn: '7d' });
  res.json({
    token,
    userId: user.id,
    username: user.username,
    fullName: user.fullName,
    role: user.role,
    deviceId: user.deviceId,
    isApproved: Boolean(user.isApproved)
  });
});

app.get('/auth/me', authMiddleware, (req, res) => {
  const user = db.users.find(u => u.id === req.user.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const { password, ...safeUser } = user;
  res.json(safeUser);
});

// DEVICE BINDING
app.put('/user/bind-device', authMiddleware, (req, res) => {
  const user = db.users.find(u => u.id === req.user.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const { deviceId, deviceModel } = req.body;
  if (!deviceId) return res.status(400).json({ error: 'deviceId required' });

  if (!user.deviceId) {
    user.deviceId = deviceId;
    user.deviceModel = deviceModel || 'Mobile Device';
    user.isApproved = true;
    saveDb();
    return res.json({ message: 'Primary device bound successfully and approved!', deviceId, isApproved: true });
  } else if (user.deviceId === deviceId) {
    return res.json({ message: 'Device already bound.', deviceId, isApproved: user.isApproved });
  } else {
    user.deviceId = deviceId;
    user.deviceModel = deviceModel || 'Mobile Device';
    user.isApproved = false;
    saveDb();
    return res.json({ message: 'New device detected. Requires Organiser approval.', deviceId, isApproved: false });
  }
});

app.get('/admin/pending-approvals', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const pending = db.users.filter(u => u.role === 'student' && !u.isApproved && u.deviceId);
  res.json(pending.map(({ password, ...u }) => u));
});

app.put('/admin/approve-device', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { userId, approve } = req.body;
  const user = db.users.find(u => u.id === Number(userId));
  if (!user) return res.status(404).json({ error: 'Student not found' });

  if (approve !== false) {
    user.isApproved = true;
  } else {
    user.deviceId = null;
    user.isApproved = true;
  }
  saveDb();
  res.json({ message: `Device ${approve !== false ? 'approved' : 'rejected'} successfully.` });
});

// SESSIONS
function generateToken() {
  return Math.floor(100000 + Math.random() * 900000).toString();
}

app.post('/session/start', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { title = 'Attendance Session', durationMinutes = 5 } = req.body;
  const token = generateToken();
  const expiresAt = new Date(Date.now() + durationMinutes * 60 * 1000).toISOString();

  // Deactivate previous sessions
  db.sessions.forEach(s => {
    if (s.organiserId === req.user.id) s.isActive = false;
  });

  const session = {
    id: db.sessions.length + 1,
    organiserId: req.user.id,
    title,
    durationMinutes: Number(durationMinutes),
    currentToken: token,
    recentTokens: [token],
    isActive: true,
    createdAt: new Date().toISOString(),
    expiresAt
  };
  db.sessions.push(session);
  saveDb();

  res.json({
    sessionId: session.id,
    title: session.title,
    durationMinutes: session.durationMinutes,
    currentToken: session.currentToken,
    expiresAt: session.expiresAt,
    isActive: true
  });
});

app.put('/session/rotate-token', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { sessionId, newToken } = req.body;
  const session = db.sessions.find(s => s.id === Number(sessionId) && s.isActive);
  if (!session) return res.status(404).json({ error: 'Active session not found' });

  const token = newToken || generateToken();
  session.recentTokens.unshift(session.currentToken);
  if (session.recentTokens.length > 4) session.recentTokens.pop();
  session.currentToken = token;
  saveDb();

  res.json({ success: true, newToken: token });
});

app.post('/session/close', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { sessionId } = req.body;
  const session = db.sessions.find(s => s.id === Number(sessionId));
  if (session) session.isActive = false;
  saveDb();
  res.json({ message: 'Session closed successfully' });
});

app.get('/session/active', (req, res) => {
  const activeSession = db.sessions.slice().reverse().find(s => s.isActive);
  if (!activeSession) return res.json({ active: false });

  if (new Date() > new Date(activeSession.expiresAt)) {
    activeSession.isActive = false;
    saveDb();
    return res.json({ active: false, message: 'Session expired' });
  }

  const organiser = db.users.find(u => u.id === activeSession.organiserId);
  res.json({
    active: true,
    sessionId: activeSession.id,
    title: activeSession.title,
    organiserName: organiser ? organiser.username : 'Organiser',
    currentToken: activeSession.currentToken,
    expiresAt: activeSession.expiresAt,
    durationMinutes: activeSession.durationMinutes
  });
});

// ATTENDANCE MARKING
app.post('/attendance/mark', authMiddleware, (req, res) => {
  const user = db.users.find(u => u.id === req.user.id);
  if (!user || user.role !== 'student') return res.status(403).json({ error: 'Only students can mark attendance' });

  const { sessionId, token, rssi, deviceId } = req.body;
  if (!sessionId || !token) return res.status(400).json({ error: 'Session ID and token are required' });

  // Anti-Proxy Check #1: Device bound & approved
  if (!user.deviceId) return res.status(403).json({ error: 'Your device is not registered. Please bind your device first.' });
  if (user.deviceId !== deviceId) return res.status(403).json({ error: 'Hardware device mismatch! Mark attendance only from registered device.' });
  if (!user.isApproved) return res.status(403).json({ error: 'Device registration pending Organiser approval.' });

  // Anti-Proxy Check #2: Session active
  const session = db.sessions.find(s => s.id === Number(sessionId) && s.isActive);
  if (!session) return res.status(400).json({ error: 'Session is not active or has ended' });
  if (new Date() > new Date(session.expiresAt)) {
    session.isActive = false;
    saveDb();
    return res.status(400).json({ error: 'Session time has expired' });
  }

  // Anti-Proxy Check #3: Token validity
  const validTokens = [session.currentToken, ...(session.recentTokens || [])];
  if (!validTokens.includes(String(token).trim())) {
    return res.status(400).json({ error: 'Expired or invalid security token! Codes rotate constantly.' });
  }

  // Anti-Proxy Check #4: Proximity RSSI
  const rssiVal = Number(rssi) || -70;
  if (rssiVal < -85) {
    return res.status(400).json({ error: `Proximity check failed (RSSI ${rssiVal} dBm). You must be inside the room.` });
  }

  // Anti-Proxy Check #5: One device = One student per session
  const deviceUsed = db.attendance.find(a => a.sessionId === Number(sessionId) && a.deviceId === deviceId);
  if (deviceUsed && deviceUsed.studentId !== user.id) {
    return res.status(409).json({ error: 'Proxy Alert: This device already marked attendance for another student!' });
  }

  // Already marked check
  const alreadyMarked = db.attendance.find(a => a.sessionId === Number(sessionId) && a.studentId === user.id);
  if (alreadyMarked) {
    return res.json({ message: 'Attendance already marked for this session!', alreadyPresent: true });
  }

  const newRecord = {
    id: db.attendance.length + 1,
    sessionId: Number(sessionId),
    studentId: user.id,
    timestamp: new Date().toISOString(),
    rssi: rssiVal,
    deviceId,
    status: 'Present'
  };
  db.attendance.push(newRecord);
  saveDb();

  res.json({
    success: true,
    message: 'Attendance successfully verified and marked!',
    username: user.username,
    rssi: rssiVal,
    time: new Date().toLocaleTimeString()
  });
});

// LIVE DASHBOARD
app.get('/attendance/dashboard/:sessionId', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const sessionId = Number(req.params.sessionId);
  const records = db.attendance.filter(a => a.sessionId === sessionId);

  const formatted = records.map(r => {
    const student = db.users.find(u => u.id === r.studentId) || { username: 'Unknown', fullName: 'Unknown' };
    return {
      attendanceId: r.id,
      studentId: {
        id: student.id,
        username: student.username,
        fullName: student.fullName
      },
      timestamp: r.timestamp,
      rssi: r.rssi,
      deviceId: r.deviceId,
      status: r.status
    };
  }).reverse();

  res.json(formatted);
});

app.post('/attendance/manual-add', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { sessionId, username } = req.body;
  const user = db.users.find(u => u.username.toLowerCase() === (username || '').toLowerCase().trim() && u.role === 'student');
  if (!user) return res.status(404).json({ error: `Student "${username}" not found` });

  const existing = db.attendance.find(a => a.sessionId === Number(sessionId) && a.studentId === user.id);
  if (existing) return res.status(400).json({ error: 'Student already marked present' });

  db.attendance.push({
    id: db.attendance.length + 1,
    sessionId: Number(sessionId),
    studentId: user.id,
    timestamp: new Date().toISOString(),
    rssi: 0,
    deviceId: 'Organiser Manual Override',
    status: 'Manual'
  });
  saveDb();
  res.json({ message: `Student ${username} marked present manually!` });
});

app.post('/attendance/manual-remove', authMiddleware, (req, res) => {
  if (req.user.role !== 'organiser') return res.status(403).json({ error: 'Organiser privileges required' });
  const { sessionId, studentId } = req.body;
  const index = db.attendance.findIndex(a => a.sessionId === Number(sessionId) && a.studentId === Number(studentId));
  if (index !== -1) {
    db.attendance.splice(index, 1);
    saveDb();
  }
  res.json({ message: 'Attendance record removed' });
});

// HISTORY
app.get('/attendance/history', authMiddleware, (req, res) => {
  if (req.user.role === 'student') {
    const totalSessions = db.sessions.length;
    const attended = db.attendance
      .filter(a => a.studentId === req.user.id)
      .map(a => {
        const session = db.sessions.find(s => s.id === a.sessionId) || {};
        return {
          timestamp: a.timestamp,
          rssi: a.rssi,
          status: a.status,
          sessionId: a.sessionId,
          title: session.title || 'Attendance Session',
          createdAt: session.createdAt
        };
      })
      .reverse();

    const percentage = totalSessions > 0 ? Number(((attended.length / totalSessions) * 100).toFixed(1)) : 0;
    return res.json({
      totalSessions,
      attendedSessions: attended.length,
      percentage,
      records: attended
    });
  } else {
    const sessions = db.sessions.map(s => {
      const count = db.attendance.filter(a => a.sessionId === s.id).length;
      return { ...s, presentCount: count };
    }).reverse();
    return res.json({ sessions });
  }
});

// CSV EXPORT
app.get('/attendance/export/:sessionId', (req, res) => {
  const sessionId = Number(req.params.sessionId);
  const session = db.sessions.find(s => s.id === sessionId);
  if (!session) return res.status(404).json({ error: 'Session not found' });

  const records = db.attendance.filter(a => a.sessionId === sessionId);
  let csv = 'Roll/Username,Full Name,Status,Marked At,Signal (dBm),Device ID\n';
  records.forEach(r => {
    const student = db.users.find(u => u.id === r.studentId) || { username: 'Unknown', fullName: 'Unknown' };
    csv += `"${student.username}","${student.fullName}","${r.status}","${r.timestamp}",${r.rssi},"${r.deviceId}"\n`;
  });

  const filename = `attendance_session_${sessionId}_${Date.now()}.csv`;
  res.setHeader('Content-Type', 'text/csv');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.send(csv);
});

app.get('/students', (req, res) => {
  const students = db.users
    .filter(u => u.role === 'student')
    .map(({ password, ...u }) => u);
  res.json(students);
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`🛡️ PROXYPROOF NODE SERVER LIVE ON PORT ${PORT}`);
});
