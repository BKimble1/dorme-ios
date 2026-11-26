"""DORM-E app API v1: the shared vocabulary (spec: dorme_platform/spec/API_V1.md).

Everything the iPhone app, the BLE bridge, tasks and local tools exchange with the coordinator is
defined here once. The Swift mirror is ios/DORMEKit/Sources/DORMEKit/Models.swift; the fixtures in
spec/fixtures/ are checked against both (Python tests here, Swift tests on a Mac).

Nothing in this file changes the Pi <-> ESP32 serial protocol, GPIO map or firmware limits.
"""

API_VERSION = 1
SOFTWARE_VERSION = "0.1.0"

# ---- command names (client -> coordinator) ----
CMD_STOP = "stop"
CMD_DRIVE_CLAIM = "drive.claim"
CMD_DRIVE_HOLD = "drive.hold"
CMD_DRIVE_RELEASE = "drive.release"
CMD_TASK_START = "task.start"
CMD_TASK_CANCEL = "task.cancel"
CMD_FAULT_REARM = "fault.rearm"
CMD_STATE_GET = "state.get"
CMD_CAPABILITIES_GET = "capabilities.get"

COMMANDS = (CMD_STOP, CMD_DRIVE_CLAIM, CMD_DRIVE_HOLD, CMD_DRIVE_RELEASE, CMD_TASK_START,
            CMD_TASK_CANCEL, CMD_FAULT_REARM, CMD_STATE_GET, CMD_CAPABILITIES_GET)
# Commands anyone on the network (or BLE) may send without pairing. Only stop.
UNAUTHENTICATED_COMMANDS = {CMD_STOP}

# ---- command sources ----
SOURCES = ("app", "ble", "voice", "task", "local")

# ---- drive ----
DIRECTIONS = ("F", "B", "L", "R")
DIRECTION_NAMES = {"F": "forward", "B": "back", "L": "left", "R": "right"}

# ---- acknowledgement codes (ack.code when ok is false) ----
ACK_CODES = {
    "UNAUTHORIZED": "Pair with the robot first.",
    "BAD_REQUEST": "The request was malformed.",
    "UNKNOWN_COMMAND": "The robot does not know this command.",
    "RATE_LIMITED": "Too many messages; slow down.",
    "LOCKED_OUT": "Too many wrong PINs; wait and try again.",
    "BAD_PIN": "That PIN is not correct.",
    "NO_CODE": "The code on DORM-E's screen expired or was used. Show a new one and scan it.",
    "BUSY": "Another controller or task owns movement.",
    "NOT_OWNER": "This controller does not own movement. Claim it first.",
    "STALE": "The command is out of date (old claim or old sequence number).",
    "LINK_DOWN": "The motor controller (ESP32) is not connected.",
    "NOT_READY": "The motor controller has not armed yet.",
    "FAULT": "A fault is latched. Clear it first.",
    "PLUG": "The charge plug is in.",
    "SHUTTING_DOWN": "The robot is shutting down.",
    "NETWORK_SHARED": "Driving is off on shared networks.",
    "TASK_ACTIVE": "A task is running. Cancel it first.",
    "NO_TASK": "No such task is running.",
    "UNAVAILABLE": "This feature is not available on this robot right now.",
    "CONFIRM_REQUIRED": "This needs an explicit confirm.",
    "NO_FAULT": "There is no fault to clear.",
    "REARM_REFUSED": "The motor controller refused to clear the fault.",
    "MOVE_REFUSED": "The motor controller refused the move.",
    "INTERNAL": "Internal error.",
}

# ---- task lifecycle ----
TASK_STATES = ("pending", "running", "succeeded", "failed", "cancelled")
TASK_TERMINAL = {"succeeded", "failed", "cancelled"}

# ---- motion ----
MOTION_STATES = ("stopped", "moving", "stopping")
OUTPUTS = ("enabled", "disabled_bench")

# ---- faults (ESP32 codes are copied from SOFTWARE_AND_FIRMWARE_SPEC.md section 4) ----
FAULTS = {
    "STALE": ("Command expired", "A drive command or heartbeat arrived too late; wheels stopped.", "phone_or_voice"),
    "JAM": ("Possible jam", "Sonar range did not change while driving straight.", "phone_or_voice"),
    "LOW_BUS": ("Battery low under load", "Bus voltage fell below 8.8 V while moving.", "phone_or_voice"),
    "ESP_RESET": ("Controller reset", "The ESP32 restarted after a panic, watchdog or brownout.", "phone_or_voice"),
    "INA_FAIL": ("Voltage sensor silent", "The INA219 did not answer; no low-battery protection.", "phone_or_voice"),
    "SONAR_FAIL": ("Sonar not answering", "Forward moves are refused until readings return.", "auto"),
    "RAIL_DEAD": ("Motor power did not come up", "MOT_EN rose but the motor rail did not.", "phone_or_voice"),
    "NOCUT": ("Power cut did not happen", "Still alive 10 s after KILL rose. Check Q5, R17, U14.", "phone"),
    "RAIL_LIVE": ("Motor rail live while disabled", "U15 or Q2 suspect. Service needed.", "service"),
    "RUN_SHORT": ("Switch loop wiring", "GPIO32 low with GPIO34 high. Service needed.", "service"),
    "T1_LIVE": ("Charge path live", "K2 welded or live charger with shunt closed.", "service"),
    # Coordinator-side conditions (not ESP32 latches):
    "LINK_LOST": ("Controller link lost", "No status from the ESP32 for 1 s. Stop cannot reach the wheels: use S2.", "auto"),
}

REARM_CLASSES = ("phone_or_voice", "phone", "service", "auto")

# ---- what DORM-E hardware cannot measure (shown as such, never invented) ----
NOT_MEASURED = ("current", "runtime", "temperature", "motor_rpm", "charging_status", "wheel_speed")

# ---- face states understood by the installed bootstrap face (dorme_pi_bootstrap/face.py) ----
BOOTSTRAP_FACE_STATES = ("idle", "listening", "happy", "puzzled", "low_energy", "sleepy", "fault", "pairing")

# ---- staleness rules the app applies (spec section 8, AUTH values) ----
STALE_AFTER_MS = 3000
OFFLINE_AFTER_MS = 10000

# ---- BLE layout (UUIDs are random v4, generated for DORM-E 2026-11-25) ----
BLE_SERVICE_UUID = "6f1e0001-4c2b-4b7e-9d8a-d0a7e0b10001"
BLE_STATUS_UUID = "6f1e0002-4c2b-4b7e-9d8a-d0a7e0b10001"     # read, notify: compact status JSON
BLE_SETUP_UUID = "6f1e0003-4c2b-4b7e-9d8a-d0a7e0b10001"      # read: how to reach the Wi-Fi API
BLE_COMMAND_UUID = "6f1e0004-4c2b-4b7e-9d8a-d0a7e0b10001"    # write: "STOP", or "CODE" (show pairing code + QR)
BLE_WIFI_UUID = "6f1e0005-4c2b-4b7e-9d8a-d0a7e0b10001"       # write: sealed Wi-Fi details, framed chunks
BLE_RESULT_UUID = "6f1e0006-4c2b-4b7e-9d8a-d0a7e0b10001"     # read, notify: Wi-Fi setup outcome JSON
BLE_MAX_PAYLOAD = 180   # bytes; fits a 185-byte ATT MTU that iOS normally negotiates

BONJOUR_TYPE = "_dorme._tcp"      # advertised by Avahi (deploy/dorme.avahi.service); the app browses it
DEFAULT_PORT = 8080


def ack(cmd_id, ok, code=None, message=None, result=None):
    """Build an acknowledgement. code must be one of ACK_CODES when ok is false."""
    if not ok and code not in ACK_CODES:
        raise ValueError(f"unknown ack code {code}")
    return {
        "v": API_VERSION, "type": "ack", "id": cmd_id, "ok": bool(ok),
        "code": None if ok else code,
        "message": message if message is not None else ("" if ok else ACK_CODES[code]),
        "result": result or {},
    }


def fault_info(code):
    if not code:
        return None
    title, detail, rearm = FAULTS.get(code, (code, "Unrecognised fault code.", "service"))
    return {"code": code, "title": title, "detail": detail, "rearm": rearm}
