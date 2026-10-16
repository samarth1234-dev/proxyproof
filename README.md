# 🛡️ ProxyProof — High-Security Bluetooth Attendance System

ProxyProof is an attendance management system designed to completely eliminate **proxy attendance (buddy punching)** in university and corporate environments. It utilizes **Bluetooth Low Energy (BLE)** proximity detection, **hardware device-binding**, and **high-frequency rotating cryptographic tokens**.

---

## 🚀 System Architecture & How It Works

```
┌────────────────────────────────┐         BLE & WiFi Beacon        ┌────────────────────────────────┐
│        Organiser App           │ ──────────────────────────────── │          Student App           │
│  - Starts 5-Min Session        │   (Session ID + Rotating Token)  │  - Auto-scans in room          │
│  - Rotating Token (Every 8s)   │                                  │  - Hardware Bound Device ID    │
│  - Real-Time Command Center    │                                  │  - 0-click automated marking   │
│  - Device Approval Management  │                                  │  - Attendance History & %      │
└────────────────┬───────────────┘                                  └────────────────┬───────────────┘
                 │                                                                   │
                 │                    REST API (Port 5050)                           │
                 └─────────────────────────► ┌──────────────────┐ ◄──────────────────┘
                                             │  Backend Server  │
                                             │  (Node / Python) │
                                             │  SQLite Database │
                                             └──────────────────┘
```

1. **Organiser Broadcast**: The organiser starts a session (e.g., 5-minute lecture). The app broadcasts a BLE beacon and security token that rotates automatically every 8 seconds.
2. **Student Auto-Detection**: The student app scans in the background. As soon as the student is physically in the room, the app picks up the signal and transmits the rotating token, hardware device ID, and signal strength (RSSI) with zero manual input.
3. **Multi-Layer Anti-Proxy Enforcement**:
   - **Hardware Device Binding**: Each student account is bound to one physical hardware device (`androidInfo.id` / `identifierForVendor`). Switching devices requires Organiser approval.
   - **One Device = One Student**: A physical device cannot mark attendance for more than one student per session.
   - **Rotating Token Window**: Tokens rotate every 8 seconds with an active 15-second grace window, defeating photographed or forwarded codes.
   - **Proximity RSSI Threshold**: Signals weaker than `-85 dBm` are rejected (verifying the student is physically inside the classroom and not in the hallway).
4. **Live Dashboard & Controls**: The organiser command center displays real-time attendance, live signal dBm, manual student add/remove overrides, and 1-click CSV export.

---

## 🛠️ Project Structure

```
proxyproof/
├── backend/
│   ├── server.py              # Production Python Flask Server (SQLite3 + JWT + bcrypt)
│   ├── server.js              # Production Node.js Express Server
│   ├── test_full_suite.py     # Automated test suite (16 core security tests)
│   ├── proxyproof.db          # SQLite persistent database
│   └── package.json           # Node backend dependencies
└── app/
    ├── lib/
    │   ├── main.dart          # Entry point, custom dark theme & routing
    │   ├── services/
    │   │   └── api_service.dart # HTTP client with dynamic IP configuration
    │   └── screens/
    │       ├── login_screen.dart     # Login, registration, role switch, server IP config
    │       ├── student_screen.dart   # Radar visualizer, auto-scan, history & percentage
    │       └── organiser_screen.dart # Command center, live rotating token, live feed, CSV export
    ├── android/               # Android native configuration with BLE/Location permissions
    └── pubspec.yaml           # Flutter dependencies
```

---

## ⚡ Quick Start Guide

### 1. Start the Backend Server

You can run either the Python or Node server:

```bash
cd "Documents/New project/proxyproof/backend"

# Option A: Python Flask Server (Recommended)
python3 server.py

# Option B: Node.js Server
node server.js
```

The server binds to `0.0.0.0:5050` (accessible locally at `http://172.17.176.112:5050`).

### 2. Run the Automated Verification Suite

To verify all anti-proxy security rules and API endpoints:

```bash
cd "Documents/New project/proxyproof/backend"
python3 test_full_suite.py
```

### 3. Run the Flutter Mobile App

Ensure your Android or iOS device is connected via USB or emulator is running:

```bash
cd "Documents/New project/proxyproof/app"
flutter run
```

> **Tip**: If running on a physical phone connected over Wi-Fi, tap the **⚙️ Settings** icon on the top-right of the Login screen to set your laptop's IP address (e.g. `http://172.17.176.112:5050`).

---

## 📋 Features Checklist (Completed)

- [x] **Organiser and Student roles with login**
- [x] **Hardware device binding with admin approval for device changes**
- [x] **Organiser session broadcast with configurable duration (e.g. 5 min)**
- [x] **0-click automated attendance marking when student is in proximity**
- [x] **Anti-proxy rotating security tokens (rotates every 8s)**
- [x] **Anti-proxy RSSI signal strength validation (physical room presence check)**
- [x] **Anti-proxy buddy punching guard (one device marks only one student)**
- [x] **Live real-time dashboard showing marks as they occur**
- [x] **Organiser manual add and remove overrides**
- [x] **Student attendance history with visual percentage gauge**
- [x] **1-Click Attendance CSV Export for Organisers**
