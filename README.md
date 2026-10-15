# ProxyProof - Bluetooth Attendance System

A fully working system to prevent proxy attendance using BLE rotating tokens and device binding.

## Backend Setup (Node.js + MongoDB)
1. Navigate to `proxyproof/backend`.
2. Run `npm install`.
3. Ensure MongoDB is running locally on `mongodb://localhost:27017`.
4. Run `node server.js`.
5. The server will start on port 3000.

## Frontend Setup (Flutter)
1. Install Flutter SDK on your machine.
2. Navigate to `proxyproof/app`.
3. Run `flutter pub get`.
4. Replace `YOUR_SERVER_IP` in `lib/services/api_service.dart` with your computer's local IP address.
5. Run `flutter run` on an actual Android/iOS device (BLE does not work on simulators).

## How it Works
- **Organiser**: Starts a session \u2192 Server generates initial token \u2192 App broadcasts this token via BLE.
- **Rotation**: Every 10 seconds, the Organiser app updates the token on the server and in the BLE broadcast.
- **Student**: Scans for the Organiser \u2192 Picks up token and RSSI \u2192 Sends `{studentId, token, rssi, deviceId}` to server.
- **Verification**: Server checks:
  1. Is the student's `deviceId` bound and approved?
  2. Does the `token` match the current session token?
  3. Is the `rssi` indicating proximity (e.g., \u2264 -60dBm)?
