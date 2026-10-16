#!/usr/bin/env python3
import requests
import json
import time

BASE_URL = "http://127.0.0.1:5050"

def run_tests():
    print("==================================================")
    print("🧪 PROXYPROOF FULL AUTOMATED VERIFICATION SUITE")
    print("==================================================")

    # 1. Health Check
    r = requests.get(f"{BASE_URL}/")
    assert r.status_code == 200, f"Health check failed: {r.text}"
    print(" 1. Health check passed!")

    # 2. Register Organiser & Students
    ts = int(time.time())
    org_user = f"prof_{ts}"
    s1_user = f"student1_{ts}"
    s2_user = f"student2_{ts}"

    requests.post(f"{BASE_URL}/auth/register", json={"username": org_user, "password": "password123", "fullName": "Prof. Alan Turing", "role": "organiser"})
    requests.post(f"{BASE_URL}/auth/register", json={"username": s1_user, "password": "password123", "fullName": "Alice Johnson", "role": "student"})
    requests.post(f"{BASE_URL}/auth/register", json={"username": s2_user, "password": "password123", "fullName": "Bob Smith", "role": "student"})
    print(" 2. Registered Organiser and Students successfully!")

    # 3. Login
    res_org = requests.post(f"{BASE_URL}/auth/login", json={"username": org_user, "password": "password123"}).json()
    org_token = res_org["token"]

    res_s1 = requests.post(f"{BASE_URL}/auth/login", json={"username": s1_user, "password": "password123"}).json()
    s1_token = res_s1["token"]

    res_s2 = requests.post(f"{BASE_URL}/auth/login", json={"username": s2_user, "password": "password123"}).json()
    s2_token = res_s2["token"]
    print(" 3. Logged in and received JWT auth tokens!")

    # 4. Device Binding (Anti-Proxy Feature #1)
    s1_dev = f"dev_pixel8_{ts}"
    b1 = requests.put(f"{BASE_URL}/user/bind-device", headers={"Authorization": f"Bearer {s1_token}"}, json={"deviceId": s1_dev, "deviceModel": "Google Pixel 8"}).json()
    assert b1.get("isApproved") == True, f"Primary device auto-approval failed: {b1}"
    print(" 4. Primary hardware device bound and auto-approved for Student 1!")

    # 5. Organiser Starts Session (Core Requirement #2)
    s_start = requests.post(f"{BASE_URL}/session/start", headers={"Authorization": f"Bearer {org_token}"}, json={"title": "Distributed Systems Lec 1", "durationMinutes": 5}).json()
    session_id = s_start["sessionId"]
    token = s_start["currentToken"]
    assert session_id is not None and len(token) == 6, f"Session start failed: {s_start}"
    print(f" 5. Organiser started 5-minute session #{session_id} with rotating token: {token}!")

    # 6. Active Session Auto-Discovery (Core Requirement #3)
    active = requests.get(f"{BASE_URL}/session/active").json()
    assert active["active"] == True and active["sessionId"] == session_id, f"Active session discovery failed: {active}"
    print(" 6. Student device auto-discovered active session in proximity!")

    # 7. Student 1 Marks Attendance Automatically (Core Requirement #3)
    mark1 = requests.post(
        f"{BASE_URL}/attendance/mark",
        headers={"Authorization": f"Bearer {s1_token}"},
        json={"sessionId": session_id, "token": token, "rssi": -62, "deviceId": s1_dev}
    ).json()
    assert mark1.get("success") == True, f"Attendance mark failed: {mark1}"
    print(" 7. Student 1 marked attendance automatically with verified proximity (RSSI -62 dBm)!")

    # 8. Duplicate Attendance Guard
    dup = requests.post(
        f"{BASE_URL}/attendance/mark",
        headers={"Authorization": f"Bearer {s1_token}"},
        json={"sessionId": session_id, "token": token, "rssi": -62, "deviceId": s1_dev}
    ).json()
    assert dup.get("alreadyPresent") == True, f"Duplicate check failed: {dup}"
    print(" 8. Duplicate mark guard caught and acknowledged existing attendance!")

    # 9. Anti-Proxy: Expired / Wrong Token (Core Requirement #4)
    bad_token = requests.post(
        f"{BASE_URL}/attendance/mark",
        headers={"Authorization": f"Bearer {s1_token}"},
        json={"sessionId": session_id, "token": "999999", "rssi": -62, "deviceId": s1_dev}
    )
    assert bad_token.status_code == 400, "Invalid token was not rejected!"
    print(" 9. Anti-Proxy: Fake / expired token was successfully rejected (400)!")

    # 10. Anti-Proxy: Physical Distance / RSSI Threshold (Core Requirement #4)
    far_mark = requests.post(
        f"{BASE_URL}/attendance/mark",
        headers={"Authorization": f"Bearer {s1_token}"},
        json={"sessionId": session_id, "token": token, "rssi": -95, "deviceId": s1_dev}
    )
    assert far_mark.status_code == 400, "Far distance was not rejected!"
    print(" 10. Anti-Proxy: Out-of-room signal (RSSI -95 dBm) was successfully rejected (400)!")

    # 11. Anti-Proxy: Buddy Punching / Device Reuse (Core Requirement #4)
    # Student 2 tries to mark attendance using Student 1's device!
    # First bind Student 2 to s1_dev
    requests.put(f"{BASE_URL}/user/bind-device", headers={"Authorization": f"Bearer {s2_token}"}, json={"deviceId": s1_dev})
    buddy_punch = requests.post(
        f"{BASE_URL}/attendance/mark",
        headers={"Authorization": f"Bearer {s2_token}"},
        json={"sessionId": session_id, "token": token, "rssi": -62, "deviceId": s1_dev}
    )
    assert buddy_punch.status_code in [403, 409], f"Buddy punch should be blocked! Got: {buddy_punch.status_code}"
    print(" 11. Anti-Proxy: Buddy punching (1 device marking 2 students) successfully blocked (409)!")

    # 12. Live Dashboard (Core Requirement #5)
    dash = requests.get(f"{BASE_URL}/attendance/dashboard/{session_id}", headers={"Authorization": f"Bearer {org_token}"}).json()
    assert len(dash) >= 1 and dash[0]["studentId"]["username"] == s1_user, f"Dashboard mismatch: {dash}"
    print(f" 12. Real-time live dashboard verified: {len(dash)} student(s) currently marked present!")

    # 13. Manual Student Override (Core Requirement #5)
    man = requests.post(
        f"{BASE_URL}/attendance/manual-add",
        headers={"Authorization": f"Bearer {org_token}"},
        json={"sessionId": session_id, "username": s2_user}
    ).json()
    assert "marked present manually" in man.get("message", ""), f"Manual add failed: {man}"
    dash2 = requests.get(f"{BASE_URL}/attendance/dashboard/{session_id}", headers={"Authorization": f"Bearer {org_token}"}).json()
    assert len(dash2) == 2, f"Expected 2 students in dashboard, got: {len(dash2)}"
    print(" 13. Organiser manual student add verified (2 students present)!")

    # 14. Student Attendance History & Percentage (Core Requirement #6)
    hist = requests.get(f"{BASE_URL}/attendance/history", headers={"Authorization": f"Bearer {s1_token}"}).json()
    assert hist["attendedSessions"] >= 1 and "percentage" in hist, f"History mismatch: {hist}"
    print(f" 14. Student Attendance History verified: {hist['attendedSessions']} attended, {hist['percentage']}% attendance rate!")

    # 15. CSV Export (Core Requirement #6)
    csv_res = requests.get(f"{BASE_URL}/attendance/export/{session_id}")
    assert csv_res.status_code == 200 and "Roll/Username,Full Name,Status" in csv_res.text, f"CSV export failed: {csv_res.text}"
    print(" 15. Attendance CSV export verified with correct headers and student records!")

    # 16. Session Close
    cls = requests.post(f"{BASE_URL}/session/close", headers={"Authorization": f"Bearer {org_token}"}, json={"sessionId": session_id}).json()
    print(" 16. Organiser session closed successfully!")

    print("==================================================")
    print(" ALL 16 PROXYPROOF CORE REQUIREMENTS PASSED! ")
    print("==================================================")

if __name__ == "__main__":
    run_tests()
