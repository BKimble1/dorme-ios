"""Coordinator configuration. Hardware file: /etc/dorme/coordinator.json (all keys optional).

Values copied from dorme_robot/dorme/common.py DEFAULT_CONFIG must agree with the robot.json that
dorme-linkd reads (speed_low_pct, speed_turn_pct, move_ms, heartbeat_ms, link_lost_ms). Motion
LIMITS are not here: the ESP32 firmware owns them and they cannot be set over serial.
"""
import json
import logging
from pathlib import Path

DEFAULTS = {
    # Safety gates
    "bench_mode": True,             # motor outputs disabled: no MOVE/DRV forwarded, pi_ready withheld
    "network_trust": "shared",      # "shared" turns driving off (spec section 8); "private" allows it
    # Networking
    "host": "0.0.0.0",
    "port": 8080,
    "trust_loopback": True,         # 127.0.0.1 callers (BLE bridge, local tools) skip pairing
    "pin_file": "/var/lib/dorme/web.json",          # existing dorme-web PIN store, read only
    "state_dir": "/var/lib/dorme/coordinator",
    # Motion (must match robot.json used by linkd)
    "hold_lease_ms": 500,           # app hold keeps ownership this long (spec: web_hold_ms)
    "link_hold_ms": 500,
    "hold_interval_ms": 200,        # what the app is told to send (5 Hz)
    "speed_low_pct": 30,
    "speed_turn_pct": 60,
    "move_ms": {"F": 2000, "B": 1000, "L": 800, "R": 800},
    "heartbeat_ms": 100,
    "link_lost_ms": 1000,
    # Battery
    "low_battery_warn_mv": None,    # set from discharge log B22; None = no warning band yet
    "battery_settle_ms": 5000,
    # Peripherals
    "face_state_dir": "/run/dorme-face",
    "linkd_socket": "/run/dorme/link.sock",
    "ble_status_file": "/run/dorme/ble.json",
    "audio_card_match": "USB",
    "camera_width": 640,
    "camera_height": 480,
    "camera_fps": 8,
    "camera_rotation_deg": None,    # unknown until the bench frame test (spec section 7b)
}

SIM_OVERRIDES = {
    "network_trust": "private",
    "trust_loopback": False,
    "pin_file": None,
    "low_battery_warn_mv": 9000,    # SIMULATED threshold so the low-battery path can be shown
}


def load(path=None, simulator=False):
    config = json.loads(json.dumps(DEFAULTS))
    if simulator:
        config.update(SIM_OVERRIDES)
    if path:
        try:
            config.update(json.loads(Path(path).read_text()))
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as exc:
            logging.getLogger("dorme-coord").error("Bad config %s (%s); using defaults", path, exc)
    if config["network_trust"] not in ("shared", "private"):
        config["network_trust"] = "shared"
    return config
