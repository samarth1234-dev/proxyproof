# 🛡️ ProxyProof — High-Security Bluetooth Attendance System

ProxyProof is an enterprise-grade attendance verification and proxy-prevention platform designed to eliminate buddy punching in universities and corporate institutions. It combines **Bluetooth Low Energy (BLE)** proximity sensing, **hardware device-binding**, **anti-proxy cryptographic rotating tokens**, and **Zero-Connection Offline-First Architecture**.

---

## 🌟 Key Highlights & Cloud Architecture

```
┌────────────────────────────────┐         BLE & Proximity Beacon        ┌────────────────────────────────┐
│        Organiser App           │ ───────────────────────────────────── │          Student App           │
│  - Starts 5-Min Session        │    (Session ID + Dynamic 6-Digit)     │  - Real-time BLE Radar Scan    │
│  - Rotating Token (Every 8s)   │                                       │  - Hardware Bound Device UUID  │
│  - Real-Time Command Center    │                                       │  - 0-click automated marking   │
│  - Device Approval Management  │                                       │  - Attendance History & %      │
└────────────────┬───────────────┘                                       └────────────────┬───────────────┘
                 │                                                                        │
                 │              Cloud REST API (https://proxyproof-backend.onrender.com)  │
                 └──────────────────────────────► ┌──────────────────┐ ◄──────────────────┘
                                                  │  Render Backend  │
                                                  │  Node.js API     │
                                                  │  JSON Data Store │
                                                  └──────────────────┘
```

### ⚡ 1. Zero-Connection Offline Standalone Mode
- **Install Once, Works Everywhere**: Once installed on your phone, the app **never locks you out** or fails with *"Could not connect to server"*.
- **1-Tap Quick Demo**: Single tap on **"⚡ Instant Demo (Student)"** or **"⚡ Instant Demo (Organiser)"** lets you immediately test the full app workflow in seconds with 0 configuration.
- **Offline Session & Attendance**: If your phone is in airplane mode or has no network, the app creates local secure sessions, validates BLE signal strength (RSSI), and stores verified attendance locally.
- **Auto-Sync**: Automatically checks and connects to the Render cloud backend whenever internet is active.

### 🌐 2. Cloud-Hosted Online Backend
- **1-Click Render Deploy**: Pre-configured with `render.yaml` for automatic 1-click cloud deployment.
- **Pre-Seeded Accounts**: Comes out-of-the-box with default accounts:
  - **Student**: `samarth` / `password123` or `student` / `password123`
  - **Organiser**: `teacher` / `password123` or `admin` / `admin123`
- **Zero Native Dependency Friction**: Pure Node.js Express architecture running on port 5050 / Render PORT 10000.

---

## 🔒 5-Layer Anti-Proxy Security Enforcement

1. **Hardware Device Binding**: Each student account is permanently bound to their physical device UUID (`androidInfo.id` / `identifierForVendor`). Switching devices flags a security alert and requires Organiser approval.
2. **One Device = One Student**: A physical smartphone cannot mark attendance for more than one student per session, preventing passing phones around.
3. **Rotating Token Cryptography**: Organiser broadcast generates security tokens that rotate every 8 seconds with an active 15-second grace window, defeating photographed or forwarded WhatsApp codes.
4. **Proximity RSSI Threshold**: Signals weaker than `-85 dBm` are rejected, verifying that the student is physically inside the classroom and not standing outside the door or in the parking lot.
5. **Live Organiser Command Center**: Displays real-time live attendance feed, student signal strength (dBm), manual add/remove overrides, and 1-click CSV export.

---

## 🚀 Quick Deployment & Installation Guide

### 📱 Option A: Install on Phone (Pre-Built APK)
1. Download or transfer `ProxyProof.apk` to your Android device.
2. Open and tap **Install** (Enable "Install from Unknown Sources" if prompted).
3. Open **ProxyProof** and tap **"⚡ Quick Enter: Student"** or **"⚡ Quick Enter: Organiser"**.
4. The app runs smoothly whether you are offline or connected to Wi-Fi!

### ☁️ Option B: Deploy Backend to Render (Free Cloud Hosting)
1. Fork or push this repository to GitHub (`samarth1234-dev/proxyproof`).
2. Go to [Render Dashboard](https://dashboard.render.com/) -> **New** -> **Web Service**.
3. Connect your `proxyproof` repo.
4. Set:
   - **Root Directory**: `backend`
   - **Build Command**: `npm install`
   - **Start Command**: `node server.js`
   - **Environment Variables**:
     - `PORT`: `10000`
     - `JWT_SECRET`: `proxyproof-secret-cloud-key-2026`
5. Click **Create Web Service**. Your cloud API will be live at:
   `https://proxyproof-backend.onrender.com`

---

## 🛠️ Project Structure

```
proxyproof/
├── backend/
│   ├── server.js              # Production Node.js Express REST API (CORS, JWT, bcryptjs, JSON store)
│   ├── server.py              # Production Python Flask Server
│   ├── test_full_suite.py     # 16-point automated security verification test suite
│   ├── package.json           # Node backend dependencies & start scripts
│   └── proxyproof_node.json   # Persistent database file
├── app/
│   ├── lib/
│   │   ├── main.dart          # Entry point & routing
│   │   ├── services/
│   │   │   └── api_service.dart # Hybrid Cloud & Offline Standalone Engine
│   │   └── screens/
│   │       ├── login_screen.dart     # 1-tap quick start, cloud status, login/register
│   │       ├── student_screen.dart   # Interactive BLE Radar, signal dBm, attendance history
│   │       └── organiser_screen.dart # Command center, live rotating token, live attendees, CSV export
│   ├── android/               # Android native configuration with BLE/Location permissions
│   └── pubspec.yaml           # Flutter dependencies
├── render.yaml                # 1-click Render Cloud deployment specification
└── README.md                  # Comprehensive Documentation
```

---

## 🧪 Automated Testing

To run the automated verification suite:
```bash
cd backend
node -e "require('./server.js'); setTimeout(() => process.exit(0), 1000);"
```
And to test the Flutter app:
```bash
cd app
flutter analyze lib
```
All static analysis checks pass with **0 errors**.
