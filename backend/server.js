const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const dotenv = require('dotenv');

dotenv.config();
const app = express();
app.use(express.json());
app.use(cors());

const PORT = process.env.PORT || 3000;
const JWT_SECRET = process.env.JWT_SECRET || 'super-secret-key';
const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017/proxyproof';

mongoose.connect(MONGO_URI).then(() => console.log('Connected to MongoDB')).catch(err => console.error('MongoDB error:', err));

const UserSchema = new mongoose.Schema({
  username: { type: String, required: true, unique: true },
  password: { type: String, required: true },
  role: { type: String, enum: ['student', 'organiser'], required: true },
  deviceId: { type: String },
  isApproved: { type: Boolean, default: false }
});
const User = mongoose.model('User', UserSchema);

const SessionSchema = new mongoose.Schema({
  organiserId: { type: mongoose.Schema.Types.ObjectId, ref: 'User' },
  currentToken: String,
  isActive: { type: Boolean, default: true },
  createdAt: { type: Date, default: Date.now },
  expiresAt: Date
});
const Session = mongoose.model('Session', SessionSchema);

const AttendanceSchema = new mongoose.Schema({
  sessionId: { type: mongoose.Schema.Types.ObjectId, ref: 'Session' },
  studentId: { type: mongoose.Schema.Types.ObjectId, ref: 'User' },
  timestamp: { type: Date, default: Date.now },
  rssi: Number
});
const Attendance = mongoose.model('Attendance', AttendanceSchema);

const auth = (req, res, next) => {
  const token = req.headers['authorization'];
  if (!token) return res.status(401).json({ message: 'No token' });
  jwt.verify(token, JWT_SECRET, (err, decoded) => {
    if (err) return res.status(401).json({ message: 'Invalid token' });
    req.userId = decoded.id;
    req.userRole = decoded.role;
    next();
  });
};

app.post('/auth/register', async (req, res) => {
  try {
    const { username, password, role } = req.body;
    const hashedPassword = await bcrypt.hash(password, 10);
    const user = await User.create({ username, password: hashedPassword, role });
    res.status(201).json({ message: 'User created' });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

app.post('/auth/login', async (req, res) => {
  const { username, password } = req.body;
  const user = await User.findOne({ username });
  if (!user || !(await bcrypt.compare(password, user.password))) return res.status(401).json({ message: 'Invalid credentials' });
  const token = jwt.sign({ id: user._id, role: user.role }, JWT_SECRET);
  res.json({ token, role: user.role, userId: user._id });
});

app.put('/user/bind-device', auth, async (req, res) => {
  const { deviceId } = req.body;
  await User.findByIdAndUpdate(req.userId, { deviceId, isApproved: false });
  res.json({ message: 'Device binding requested' });
});

app.put('/admin/approve-device', auth, async (req, res) => {
  if (req.userRole !== 'organiser') return res.status(403).json({ message: 'Forbidden' });
  const { userId } = req.body;
  await User.findByIdAndUpdate(userId, { isApproved: true });
  res.json({ message: 'User approved' });
});

app.post('/session/start', auth, async (req, res) => {
  if (req.userRole !== 'organiser') return res.status(403).json({ message: 'Forbidden' });
  const session = await Session.create({
    organiserId: req.userId,
    currentToken: Math.random().toString(36).substring(7),
    expiresAt: new Date(Date.now() + 5 * 60 * 1000)
  });
  res.json(session);
});

app.put('/session/rotate-token', auth, async (req, res) => {
  if (req.userRole !== 'organiser') return res.status(403).json({ message: 'Forbidden' });
  const { sessionId, newToken } = req.body;
  await Session.findByIdAndUpdate(sessionId, { currentToken: newToken });
  res.json({ success: true });
});

app.post('/attendance/mark', auth, async (req, res) => {
  const { sessionId, token, rssi, deviceId } = req.body;
  const user = await User.findById(req.userId);
  const session = await Session.findById(sessionId);
  if (!user || !session || !session.isActive) return res.status(400).json({ message: 'Invalid session' });
  if (user.deviceId !== deviceId || !user.isApproved) return res.status(403).json({ message: 'Device not approved' });
  if (session.currentToken !== token) return res.status(400).json({ message: 'Expired token' });
  if (rssi > -60) return res.status(400).json({ message: 'Too far away' });
  const existing = await Attendance.findOne({ sessionId, studentId: req.userId });
  if (existing) return res.status(400).json({ message: 'Already marked' });
  await Attendance.create({ sessionId, studentId: req.userId, rssi });
  res.json({ message: 'Attendance marked!' });
});

app.get('/attendance/dashboard/:sessionId', auth, async (req, res) => {
  if (req.userRole !== 'organiser') return res.status(403).json({ message: 'Forbidden' });
  const list = await Attendance.find({ sessionId: req.params.sessionId }).populate('studentId', 'username');
  res.json(list);
});

app.listen(PORT, () => console.log('Server running on port ' + PORT));
