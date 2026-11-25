"""Portable ESP32 stand-in that speaks the real serial frames (spec section 2). SIMULATOR ONLY.

Unlike dorme_robot/dorme/sim_esp32.py (Linux pty), this one is transport-free: feed it bytes,
call tick(), read bytes back. It runs on Windows, macOS and the Pi, so the coordinator, the app
and the tests can be exercised with no hardware. It is NOT the firmware and NOT a safety
reference: the real rules live in dorme_esp32/lib/dorme_core (tested by its own host tests).

Behaviour copied from the firmware/spec where the coordinator depends on it:
- BOOT every 500 ms until HELLO; WAIT_LINK until HB with pi_ready=1 is fresh; then ARMING, READY.
- A MOVE lives only while HB frames carry its move_id (gap < 300 ms). A DRV lives 300 ms from its
  own arrival; HB frames never extend a DRV. Expiry -> PWM 0, MOVE_DONE EXPIRED, fault STALE.
- STOP sets PWM 0 at once. Faults latch MOT_EN low. REARM needs a stopped robot.
- Forward obstacle refuse 30 cm / stop 20 cm. LOW_BUS below 8.8 V while moving.
Sensor values are SYNTHETIC defaults (vbus 9600 mV, sonar 120 cm) and are labelled simulated
by the coordinator. They are not readings from DORM-E.
"""
import time

from .legacy import protocol as P

HB_EXPIRY_MS = 300
CEILING_MS = {"F": 3000, "B": 1500, "L": 1500, "R": 1500}
PWM_MAX_PCT = 60
CAP_MS = 3000
OBST_REFUSE_CM, OBST_STOP_CM = 30, 20
LOW_BUS_MV = 8800
REARMABLE = P.REARMABLE


class Esp32Sim:
    def __init__(self, clock=None, fw="sim-0.1"):
        self.clock = clock or (lambda: int(time.monotonic() * 1000))
        self.fw = fw
        self.out = bytearray()
        self.splitter = P.LineSplitter()
        self.seq = P.SeqCounter()
        self.frames_in = []          # every decoded frame received, for tests
        self.vbus = 9600
        self.sonar = 120
        self.connected = True        # False = USB unplugged: nothing in, nothing out
        self.reset("POWERON")

    # ---------- helpers ----------
    def now(self):
        return self.clock()

    def reset(self, reason="SW"):
        now = self.now()
        self.state = "BOOT"
        self.reset_reason = reason
        self.nonce = None
        self.fault = None
        self.mot_en = 0
        self.pwm = [0, 0]
        self.dir = "FF"
        self.motion = None           # dict(move_id, kind, is_drv, until, last_keep, start)
        self.last_hb = None
        self.pi_ready = False
        self.hb_gap_max = 0
        self.inputs = 0
        self.off_reason = None
        self.off_acked = False
        self.boot_ms = now
        self.last_boot_tx = -10_000
        self.last_stat_tx = now
        self.last_off_tx = -10_000
        self.arming_at = None
        self.silence_until = 0
        self.splitter = P.LineSplitter()

    def tx(self, ftype, *values):
        if not self.connected or self.now() < self.silence_until:
            return
        self.out.extend(P.encode(ftype, self.seq.next(), *values))

    def take_output(self) -> bytes:
        data = bytes(self.out)
        self.out.clear()
        return data

    def hb_fresh(self, now):
        return self.last_hb is not None and now - self.last_hb <= HB_EXPIRY_MS

    def moving(self):
        return self.motion is not None

    def end_motion(self, reason):
        if self.motion:
            on_ms = self.now() - self.motion["start"]
            self.tx("MOVE_DONE", self.motion["move_id"], reason, on_ms)
        self.motion = None
        self.pwm = [0, 0]
        if self.state == "MOVING":
            self.state = "READY"

    def latch_fault(self, code, detail="-"):
        self.end_motion("FAULT" if code not in ("STALE",) else "EXPIRED")
        self.fault = code
        if code != "SONAR_FAIL":
            self.mot_en = 0
            self.state = "FAULT"
        self.tx("FAULT", code, detail)

    # ---------- test controls (simulator only) ----------
    def control(self, name, value=None):
        if name == "vbus":
            self.vbus = int(value)
        elif name == "sonar":
            self.sonar = int(value)
        elif name == "fault":
            self.latch_fault(str(value))
        elif name == "s2off":
            self.inputs |= P.INPUT_GPIO32_HIGH
            self.begin_off("S2")
        elif name == "plug":
            self.inputs |= P.INPUT_GPIO34_HIGH
            self.begin_off("PLUG")
        elif name == "reset":
            self.reset(str(value or "SW"))
        elif name == "silence":
            self.silence_until = self.now() + int(float(value) * 1000)
        elif name == "unplug":
            self.connected = False
        elif name == "replug":
            self.connected = True
        else:
            raise ValueError(f"unknown control {name}")

    def begin_off(self, reason):
        self.end_motion("OFF")
        self.mot_en = 0
        self.off_reason = reason
        self.state = "OFF_WAIT_ACK"
        self.last_off_tx = -10_000

    # ---------- input ----------
    def feed(self, data: bytes):
        if not self.connected:
            return
        for line in self.splitter.feed(data):
            try:
                frame = P.decode(line)
            except P.FrameError:
                continue
            self.frames_in.append(frame)
            self.on_frame(frame)

    def on_frame(self, frame):
        f, t, now = frame.fields, frame.type, self.now()
        if frame.token:
            if t == "HALTED" and self.state == "OFF_WAIT_TOKEN":
                self.state = "SETTLE"
            return
        if t == "HELLO":
            self.nonce = f["nonce"]
            self.tx("HELLO_ACK", self.nonce)
            if self.state == "BOOT":
                self.state = "WAIT_LINK"
        elif t == "HB":
            if self.last_hb is not None:
                self.hb_gap_max = max(self.hb_gap_max, now - self.last_hb)
            self.last_hb = now
            self.pi_ready = f["pi_ready"] == 1
            m = self.motion
            if m and not m["is_drv"] and f["move_id"] == m["move_id"]:
                m["last_keep"] = now       # HB keeps only a MOVE with the same id alive
        elif t == "STOP":
            if self.motion:
                self.end_motion("STOP")
            self.pwm = [0, 0]
        elif t == "MOVE":
            self.on_move(f, now)
        elif t == "DRV":
            self.on_drv(f, now)
        elif t == "REARM":
            if not self.fault:
                self.tx("REARM_NAK", "NOFAULT")
            elif self.fault not in REARMABLE:
                self.tx("REARM_NAK", "CLASS")
            elif self.moving():
                self.tx("REARM_NAK", "MOVING")
            elif self.fault == "LOW_BUS" and self.vbus < LOW_BUS_MV:
                self.tx("REARM_NAK", "CAUSE")
            else:
                self.fault = None
                self.state = "WAIT_LINK"
                self.tx("REARM_OK", "-")
        elif t == "OFF_ACK":
            if self.state == "OFF_WAIT_ACK":
                self.off_acked = True
                self.state = "OFF_WAIT_TOKEN"

    def refuse(self, move_id, kind, now):
        if self.state == "FAULT" or (self.fault and self.fault != "SONAR_FAIL"):
            return "FAULT"
        if self.off_reason:
            return "OFFPATH"
        if self.state == "MOVING":
            return "BUSY"
        if self.state != "READY":
            return "NOTREADY"
        if not self.hb_fresh(now):
            return "STALE"
        if self.vbus < LOW_BUS_MV:
            return "LOWBUS"
        if kind == "F" and self.fault == "SONAR_FAIL":
            return "NOSONAR"
        if kind == "F" and 0 <= self.sonar < OBST_REFUSE_CM:
            return "OBST"
        return None

    def on_move(self, f, now):
        kind = f["kind"]
        if kind not in CEILING_MS or not 0 < f["speed_pct"] <= 100 or f["dur_ms"] <= 0:
            self.tx("MOVE_NAK", f["move_id"], "RANGE")
            return
        reason = self.refuse(f["move_id"], kind, now)
        if reason:
            self.tx("MOVE_NAK", f["move_id"], reason)
            return
        granted_ms = min(f["dur_ms"], CEILING_MS[kind])
        pct = min(f["speed_pct"], PWM_MAX_PCT)
        self.start_motion(f["move_id"], kind, False, pct, now, until=now + granted_ms)
        self.tx("MOVE_ACK", f["move_id"], granted_ms, pct)

    def on_drv(self, f, now):
        left, right = f["left_pct"], f["right_pct"]
        if not (-100 <= left <= 100 and -100 <= right <= 100):
            self.tx("MOVE_NAK", f["move_id"], "RANGE")
            return
        kind = {(1, 1): "F", (-1, -1): "B", (-1, 1): "L", (1, -1): "R"}.get(
            ((left > 0) - (left < 0), (right > 0) - (right < 0)))
        m = self.motion
        if m and m["is_drv"] and m["move_id"] == f["move_id"]:
            if kind != m["kind"]:
                self.tx("MOVE_NAK", f["move_id"], "BUSY")   # sign change needs STOP first
                return
            m["last_keep"] = now                          # each DRV is valid for 300 ms
            return
        if kind is None:
            self.tx("MOVE_NAK", f["move_id"], "RANGE")
            return
        reason = self.refuse(f["move_id"], kind, now)
        if reason:
            self.tx("MOVE_NAK", f["move_id"], reason)
            return
        pct = min(max(abs(left), abs(right)), PWM_MAX_PCT)
        self.start_motion(f["move_id"], kind, True, pct, now, until=None)

    def start_motion(self, move_id, kind, is_drv, pct, now, until):
        self.motion = {"move_id": move_id, "kind": kind, "is_drv": is_drv, "until": until,
                       "last_keep": now, "start": now}
        sign = {"F": (1, 1), "B": (-1, -1), "L": (-1, 1), "R": (1, -1)}[kind]
        self.pwm = [pct, pct]
        self.dir = "".join("F" if s > 0 else "R" for s in sign)
        self.state = "MOVING"

    # ---------- 10 ms control loop ----------
    def tick(self):
        now = self.now()
        if not self.connected:
            # USB power lost: in the real robot the ESP32 dies and R1/R2/R20 hold everything off.
            if self.state != "BOOT":
                self.reset("POWERON")
            return
        if self.state == "BOOT":
            if now - self.last_boot_tx >= 500:
                self.last_boot_tx = now
                self.tx("BOOT", P.PROTO_VERSION, self.fw, self.reset_reason, 0)
        elif self.state in ("WAIT_LINK", "CHECK"):
            if self.nonce and self.hb_fresh(now) and self.pi_ready and not self.off_reason:
                self.state = "ARMING"
                self.mot_en = 1
                self.arming_at = now
            elif self.nonce and self.hb_fresh(now):
                self.state = "CHECK" if not self.pi_ready else self.state
        elif self.state == "ARMING":
            if now - self.arming_at >= 100:
                self.state = "READY"
        elif self.state in ("READY", "MOVING"):
            if not self.pi_ready and self.state == "READY":
                self.state, self.mot_en = "WAIT_LINK", 0
        m = self.motion
        if m:
            expired = now - m["last_keep"] > HB_EXPIRY_MS or (m["is_drv"] and not self.hb_fresh(now))
            if expired:
                self.latch_fault("STALE", "DRV" if m["is_drv"] else "HB")
            elif m["until"] is not None and now >= m["until"]:
                self.end_motion("TIME")
            elif now - m["start"] >= CAP_MS:
                self.end_motion("CAP")
            elif m["kind"] == "F" and 0 <= self.sonar < OBST_STOP_CM:
                self.end_motion("OBST")
            elif self.vbus < LOW_BUS_MV:
                self.latch_fault("LOW_BUS", str(self.vbus))
        if self.state in ("OFF_WAIT_ACK",) and now - self.last_off_tx >= 500:
            self.last_off_tx = now
            self.tx("OFF_REQ", self.off_reason)
        if now - self.last_stat_tx >= 100 and self.state != "BOOT":
            self.last_stat_tx = now
            self.send_stat(now)

    def send_stat(self, now):
        m = self.motion
        gap = min(self.hb_gap_max, 65535)
        self.tx("STAT", self.state, self.fault or "-", self.vbus, 0,
                int(self.vbus * 0.97) if self.mot_en else 300, self.inputs, self.mot_en,
                self.pwm[0], self.pwm[1], self.dir, self.sonar,
                m["move_id"] if m else 0, (now - m["start"]) if m else 0, gap,
                (now - self.boot_ms) // 1000)
