"""The coordinator: the one place every command source goes through.

App (Wi-Fi), BLE bridge, tasks and local tools all call Coordinator.submit(). It owns the motion
arbiter, the task manager, the face adapter and the state document, and it is the only Pi-side
client that asks the link (dorme-linkd, or the simulator) to move. It enforces:

- one movement owner at a time (motion.MotionArbiter), leases that only fresh holds extend;
- stop overrides everything: it bumps the arbiter epoch, cancels the running task and is sent to
  the link even in bench mode and even unauthenticated;
- bench mode: no MOVE/DRV/hold is forwarded and pi_ready is withheld, so the ESP32 never raises
  MOT_EN (it waits in WAIT_LINK);
- nothing resumes after a restart, a link loss or an ESP32 reset.
"""
import asyncio
import json
import logging
import time

from . import api
from .api import ack
from .legacy import protocol as P
from .motion import MotionArbiter
from .tasks import TaskManager
from . import health as H

log = logging.getLogger("dorme-coord")

STOP_LETTER = {"app": "P", "ble": "P", "voice": "V", "task": "C", "local": "S"}
STAT_FRESH_MS = 1500
TRANSIENT_DEFAULT = {"happy": 1.0, "puzzled": 1.5}
# 2026-11-25: show "sleepy" only this long after an OFF request. On a robot that really powers off, the Pi is
# gone well before this. If it is still running (bench: power-off disabled, or a cut that did not happen),
# a black screen would hide the robot, so the face falls back to its normal fault/idle look.
OFF_FACE_S = 60


def mono_ms():
    return int(time.monotonic() * 1000)


class Coordinator:
    def __init__(self, config, link, *, mode, face, camera, audio, ble, vitals=None, admin=None):
        if mode not in ("hardware", "simulator"):
            raise ValueError("mode must be hardware or simulator")
        self.config = config
        self.mode = mode
        self.bench = bool(config["bench_mode"])
        self.link = link
        self.link.on_event = self.on_link_event
        self.face = face
        self.camera = camera
        self.audio = audio
        self.ble = ble
        self.vitals = vitals or H.SystemVitals(simulated=mode == "simulator")
        self.admin = admin          # AdminClient (root helper) or None
        self.arbiter = MotionArbiter(config["hold_lease_ms"])
        self.tasks = TaskManager(self, state_dir=config.get("state_dir"))
        self.listeners = set()
        self.esp = {"linkd": False, "up": False, "ever_up": False, "stat": None, "stat_at": None,
                    "boot": None, "dry_run": None}
        self.off_reason = None
        self.off_at = None          # monotonic time of the latest OFF request
        self.pairing = None         # (code, monotonic expiry) while the on-screen pairing code is shown
        self.last_offlog = None
        self.last_off_forced = False
        self.last_stop = None
        self.move_watchers = {}
        self.rearm_waiters = []
        self.transient = None
        self.stopped_since = time.monotonic()
        self.state_seq = 0
        self.last_photo = None
        self.low_latched = None
        self._ready_sent = None
        self._loops = []
        self._last_broadcast_key = None
        self._last_broadcast_at = 0.0

    # =========================== lifecycle ===========================
    async def start(self):
        await self.link.start()
        loop = asyncio.get_running_loop()
        self._loops = [loop.create_task(self._lease_loop()), loop.create_task(self._ready_loop()),
                       loop.create_task(self._face_and_state_loop())]
        self.vitals.start()
        log.info("Coordinator up: mode=%s backend=%s bench=%s trust=%s", self.mode, self.link.name,
                 self.bench, self.config["network_trust"])

    async def close(self):
        self.vitals.stop()
        for task in self._loops:
            task.cancel()
        await self.tasks.cancel("Coordinator stopping")
        await self.link.close()

    # =========================== listeners ===========================
    def add_listener(self, fn):
        self.listeners.add(fn)

    def remove_listener(self, fn):
        self.listeners.discard(fn)

    def _broadcast(self, message):
        for fn in list(self.listeners):
            try:
                fn(message)
            except Exception:
                log.exception("listener failed")

    def emit_event(self, kind, **data):
        self._broadcast({"v": api.API_VERSION, "type": "event", "event": {"kind": kind, **data}})

    def broadcast_state(self):
        self._broadcast({"v": api.API_VERSION, "type": "state", "state": self.state()})

    # =========================== link events ===========================
    @property
    def stat(self):
        return self.esp["stat"] or {}

    def stat_age_ms(self):
        return None if self.esp["stat_at"] is None else mono_ms() - self.esp["stat_at"]

    def stat_fresh(self):
        age = self.stat_age_ms()
        return self.esp["up"] and age is not None and age <= STAT_FRESH_MS

    def motors_on(self):
        return self.stat_fresh() and bool(self.stat.get("pwm_l") or self.stat.get("pwm_r"))

    def esp_fault(self):
        code = self.stat.get("fault") if self.esp["up"] else None
        if code:
            return code
        if self.esp["ever_up"] and not self.esp["up"]:
            return "LINK_LOST"
        return None

    def _drop_motion(self, why):
        """Link loss, ESP32 reset, shutdown: forget the owner so nothing can resume later."""
        previous = self.arbiter.stop_all()
        if previous:
            self.emit_event("drive.ended", reason=why)
        task = self.tasks.current
        if task and task.uses_motion and task.state not in api.TASK_TERMINAL:
            asyncio.get_running_loop().create_task(self.tasks.cancel(why))

    def on_link_event(self, ev):
        t = ev.get("t")
        if t == "linkd":
            self.esp["linkd"] = ev["up"]
            self._ready_sent = None
            if not ev["up"]:
                self.esp["up"] = False
                self._drop_motion("dorme-linkd went away")
            self.emit_event("link.changed", linkd=ev["up"], esp32=self.esp["up"])
        elif t == "subscribed":
            self.esp.update(linkd=True, up=ev.get("link_up", False), ever_up=ev.get("ever_up", False),
                            dry_run=ev.get("dry_run"), boot=ev.get("boot"))
            if ev.get("stat"):
                self.esp.update(stat=ev["stat"], stat_at=mono_ms())
            self._ready_sent = None
        elif t == "link":
            self.esp["up"] = ev["up"]
            if ev["up"]:
                self.esp["ever_up"] = True
            else:
                self._drop_motion("Controller link lost")
            self.emit_event("link.changed", linkd=self.esp["linkd"], esp32=ev["up"])
        elif t == "stopped":
            self.stopped_since = time.monotonic()
            self.emit_event("motion.stopped", reason=ev.get("reason"))
        elif t == "off":
            self.off_reason = ev.get("reason") or "-"
            self.off_at = time.monotonic()
            self._drop_motion("Shutting down")
            self.emit_event("power.shutting_down", reason=self.off_reason)
        elif t == "esp":
            self._on_esp_frame(ev)

    def _on_esp_frame(self, ev):
        ftype = ev["type"]
        fields = {k: v for k, v in ev.items() if k not in ("t", "type")}
        if ftype == "STAT":
            was_on = self.motors_on()
            self.esp.update(stat=fields, stat_at=mono_ms(), up=True, ever_up=True)
            if was_on and not self.motors_on():
                self.stopped_since = time.monotonic()
        elif ftype == "BOOT":
            self.esp["boot"] = fields
            self._drop_motion("ESP32 restarted")
            if fields.get("flags", 0) & P.BOOT_FLAG_FORCED:
                self.last_off_forced = True
            self.emit_event("controller.boot", reset_reason=fields.get("reset_reason"), fw=fields.get("fw"))
        elif ftype in ("MOVE_ACK", "MOVE_NAK", "MOVE_DONE"):
            queue = self.move_watchers.get(fields.get("move_id"))
            if queue:
                queue.put_nowait({"type": ftype, **fields})
        elif ftype == "FAULT":
            self.emit_event("fault.raised", fault=api.fault_info(fields.get("code")))
            if fields.get("code") != "SONAR_FAIL":
                self._drop_motion(f"Fault {fields.get('code')}")
        elif ftype in ("REARM_OK", "REARM_NAK"):
            for fut in self.rearm_waiters:
                if not fut.done():
                    fut.set_result({"type": ftype, **fields})
            if ftype == "REARM_OK":
                self.emit_event("fault.cleared")
        elif ftype == "OFFLOG":
            self.last_offlog = fields
            self.last_off_forced = bool(fields.get("forced"))
        elif ftype == "OFF_REQ":
            self.off_reason = fields.get("reason")
            self.off_at = time.monotonic()

    def watch_move(self, move_id):
        queue = asyncio.Queue()
        self.move_watchers[move_id] = queue
        return queue

    def unwatch_move(self, move_id):
        self.move_watchers.pop(move_id, None)

    # =========================== policy ===========================
    def drive_block_reason(self):
        """None if a drive/motion task may start now, else an ack code."""
        if self.off_reason:
            return "SHUTTING_DOWN"
        if self.config["network_trust"] != "private":
            return "NETWORK_SHARED"
        if self.bench:
            return None      # rehearsal: ownership and leases run, nothing reaches the motors
        if not self.esp["linkd"] or not self.esp["up"]:
            return "LINK_DOWN"
        fault = self.esp_fault()
        if fault and fault != "SONAR_FAIL":
            return "FAULT"
        if self.stat.get("inputs", 0) & P.INPUT_GPIO34_HIGH:
            return "PLUG"
        if self.stat.get("state") not in ("READY", "MOVING"):
            return "NOT_READY"
        return None

    # =========================== commands ===========================
    async def submit(self, cmd, source):
        """cmd = {"id", "name", "args"}; source = {"kind", "id", "authenticated"}. Returns an ack."""
        cid = cmd.get("id") if isinstance(cmd, dict) else None
        if not isinstance(cmd, dict):
            return ack(cid, False, "BAD_REQUEST")
        name = cmd.get("name")
        args = cmd.get("args") or {}
        if name not in api.COMMANDS:
            return ack(cid, False, "UNKNOWN_COMMAND")
        if source.get("kind") not in api.SOURCES:
            return ack(cid, False, "BAD_REQUEST")
        if not source.get("authenticated") and name not in api.UNAUTHENTICATED_COMMANDS:
            return ack(cid, False, "UNAUTHORIZED")
        if not isinstance(args, dict):
            return ack(cid, False, "BAD_REQUEST")
        handler = getattr(self, "_cmd_" + name.replace(".", "_"))
        try:
            return await handler(cid, args, source)
        except (KeyError, TypeError, ValueError) as exc:
            return ack(cid, False, "BAD_REQUEST", message=f"Bad arguments ({exc.__class__.__name__}).")

    async def _cmd_stop(self, cid, args, source):
        kind = source["kind"]
        reply = await self.link.request({"cmd": "stop", "reason": STOP_LETTER[kind]})
        previous = self.arbiter.stop_all()
        cancelled = await self.tasks.cancel(f"Stopped ({kind})")
        reached = bool(reply.get("ok")) and self.esp["up"]
        self.last_stop = {"at": time.time(), "source": kind, "reached_controller": reached}
        self.emit_event("stop", source=kind, reached_controller=reached,
                        released_owner=bool(previous), cancelled_task=cancelled)
        self.broadcast_state()
        warning = None if reached else (
            "The motor controller is not connected, so this stop cannot reach the wheels. Use the S2 switch."
            if not self.bench else "Bench mode: no motor output was active. Stop recorded.")
        return ack(cid, True, result={"reached_controller": reached, "cancelled_task": cancelled,
                                      "warning": warning})

    async def _cmd_drive_claim(self, cid, args, source):
        block = self.drive_block_reason()
        if block:
            return ack(cid, False, block)
        task = self.tasks.current
        if task and task.uses_motion and task.state not in api.TASK_TERMINAL:
            return ack(cid, False, "TASK_ACTIVE")
        ok, code, token = self.arbiter.claim(source["kind"], source["id"])
        if not ok:
            return ack(cid, False, code)
        self.emit_event("drive.owner", owner=self.arbiter.view())
        return ack(cid, True, result={"claim": token, "lease_ms": self.config["hold_lease_ms"],
                                      "hold_interval_ms": self.config["hold_interval_ms"],
                                      "outputs": "disabled_bench" if self.bench else "enabled"})

    async def _cmd_drive_hold(self, cid, args, source):
        direction = args["direction"]
        if direction not in api.DIRECTIONS:
            raise ValueError("direction")
        seq = args.get("seq")
        if isinstance(seq, bool) or not isinstance(seq, int):
            raise TypeError("seq")
        block = self.drive_block_reason()
        if block:
            await self._release_if_owner(source)
            return ack(cid, False, block)
        ok, code, changed = self.arbiter.hold(source["kind"], source["id"], args.get("claim"), direction, seq)
        if not ok:
            return ack(cid, False, code)
        delivered = False
        note = "Bench mode: motor outputs disabled; nothing was sent to the controller."
        if not self.bench:
            reply = await self.link.request({"cmd": "hold", "kind": direction})
            if not reply.get("ok"):
                self.arbiter.release(source["kind"], source["id"])
                return ack(cid, False, "LINK_DOWN", message=reply.get("error"))
            delivered = not reply.get("dry_run")
            note = None if delivered else "dorme-linkd dry_run: hold logged, not sent."
        if changed:
            self.emit_event("drive.owner", owner=self.arbiter.view())
        return ack(cid, True, result={"delivered": delivered, "note": note, "direction": direction})

    async def _release_if_owner(self, source):
        if self.arbiter.release(source["kind"], source["id"]) and not self.bench:
            await self.link.request({"cmd": "release"})
            self.emit_event("drive.owner", owner=None)

    async def _cmd_drive_release(self, cid, args, source):
        released = self.arbiter.release(source["kind"], source["id"], args.get("claim"))
        if released:
            if not self.bench:
                await self.link.request({"cmd": "release"})
            self.emit_event("drive.owner", owner=None)
        return ack(cid, True, result={"released": released})

    async def _cmd_task_start(self, cid, args, source):
        action = args["action"]
        if not isinstance(action, str):
            raise TypeError("action")
        ok, code, message, task = self.tasks.start(action, {"kind": source["kind"], "id": source["id"]})
        if not ok:
            return ack(cid, False, code, message=message)
        return ack(cid, True, result={"task": task})

    async def _cmd_task_cancel(self, cid, args, source):
        ok = await self.tasks.cancel(f"Cancelled ({source['kind']})", task_id=args.get("task_id"))
        if not ok:
            return ack(cid, False, "NO_TASK")
        if self.motors_on() or self.arbiter.owner:
            await self.link.request({"cmd": "stop", "reason": STOP_LETTER[source["kind"]]})
        return ack(cid, True)

    async def _cmd_fault_rearm(self, cid, args, source):
        if args.get("confirm") is not True:
            return ack(cid, False, "CONFIRM_REQUIRED")
        code = self.stat.get("fault") if self.esp["up"] else None
        if not code:
            return ack(cid, False, "NO_FAULT")
        allowed = P.VOICE_REARMABLE if source["kind"] == "voice" else P.REARMABLE
        if code not in allowed:
            return ack(cid, False, "REARM_REFUSED", message=f"{code} cannot be cleared from here.")
        if self.motors_on():
            return ack(cid, False, "REARM_REFUSED", message="Robot is still moving.")
        fut = asyncio.get_running_loop().create_future()
        self.rearm_waiters.append(fut)
        try:
            reply = await self.link.request({"cmd": "rearm", "src": "V" if source["kind"] == "voice" else "P"})
            if not reply.get("ok"):
                return ack(cid, False, "LINK_DOWN", message=reply.get("error"))
            if reply.get("dry_run"):
                return ack(cid, True, result={"dry_run": True, "note": "dorme-linkd dry_run: REARM logged, not sent."})
            try:
                answer = await asyncio.wait_for(fut, 1.5)
            except asyncio.TimeoutError:
                return ack(cid, False, "REARM_REFUSED", message="No answer from the controller.")
        finally:
            self.rearm_waiters.remove(fut)
        if answer["type"] == "REARM_OK":
            return ack(cid, True, result={"cleared": code})
        return ack(cid, False, "REARM_REFUSED", message=f"Controller said {answer.get('reason')}.")

    async def _cmd_state_get(self, cid, args, source):
        return ack(cid, True, result={"state": self.state()})

    async def _cmd_capabilities_get(self, cid, args, source):
        return ack(cid, True, result={"capabilities": self.capabilities()})

    async def client_gone(self, kind, client):
        """A WebSocket closed or an app went away: stop if it owned movement. Never resumes."""
        owner = self.arbiter.owner
        if owner and (owner["source"], owner["client"]) == (kind, client):
            self.arbiter.release(kind, client)
            if not self.bench:
                await self.link.request({"cmd": "release"})
            self.emit_event("drive.owner", owner=None, reason="Controller disconnected")

    # =========================== face ===========================
    def face_transient(self, name, seconds=None):
        seconds = seconds or TRANSIENT_DEFAULT.get(name, 1.0)
        self.transient = (name, time.monotonic() + seconds)
        self.face.set(name, transient_s=seconds)

    def on_task_finished(self, task):
        if task.state == "succeeded" and task.action != "greet":
            self.face_transient("happy")
        elif task.state == "failed":
            self.face_transient("puzzled")

    def show_pairing(self, code, seconds, qr=None):
        """Draw the one-time pairing code (and its QR) on the robot's screen for `seconds` (never sent to any client)."""
        self.pairing = (code, time.monotonic() + seconds, qr)
        self.face.set("pairing", code=code, qr=qr)

    def hide_pairing(self):
        self.pairing = None

    def pairing_code(self):
        if self.pairing and time.monotonic() >= self.pairing[1]:
            self.pairing = None
        return self.pairing[0] if self.pairing else None

    def compute_face(self):
        if self.off_reason and self.off_at is not None and time.monotonic() - self.off_at < OFF_FACE_S:
            return "sleepy"
        if self.pairing_code():
            return "pairing"
        fault = self.esp_fault()
        if fault == "LOW_BUS":
            return "low_energy"
        if fault and fault != "SONAR_FAIL":
            return "fault"
        if self.transient and time.monotonic() < self.transient[1]:
            return self.transient[0]
        if self.motors_on() or self.arbiter.owner:
            return "moving"
        if self.battery_view()["low"]:
            return "low_energy"
        return "idle"

    # =========================== loops ===========================
    async def _lease_loop(self):
        while True:
            expired = self.arbiter.expire()
            if expired:
                log.info("Lease expired for %s:%s; stopping", expired["source"], expired["client"])
                if not self.bench:
                    await self.link.request({"cmd": "release"})
                self.emit_event("drive.owner", owner=None, reason="Hold expired")
            await asyncio.sleep(0.05)

    async def _ready_loop(self):
        """pi_ready is withheld in bench mode, so the ESP32 keeps MOT_EN low."""
        last = 0.0
        while True:
            desired = not self.bench and not self.off_reason
            now = time.monotonic()
            if self.esp["linkd"] and (self._ready_sent != desired or now - last > 5):
                reply = await self.link.request({"cmd": "ready", "value": desired})
                if reply.get("ok"):
                    if self._ready_sent is None:
                        # Fresh linkd connection: make sure nothing old is still moving.
                        await self.link.request({"cmd": "stop", "reason": "S"})
                    self._ready_sent, last = desired, now
            await asyncio.sleep(0.5)

    async def _face_and_state_loop(self):
        while True:
            try:
                name = self.compute_face()
                self.face.set(name, code=self.pairing_code() if name == "pairing" else None,
                              qr=self.pairing[2] if name == "pairing" and self.pairing else None)
                state = self.state()
                key = json.dumps({k: v for k, v in state.items() if k not in ("seq", "battery", "connection")},
                                 sort_keys=True, default=str)
                now = time.monotonic()
                if key != self._last_broadcast_key or now - self._last_broadcast_at >= 1.0:
                    self._broadcast({"v": api.API_VERSION, "type": "state", "state": state})
                    self._last_broadcast_key, self._last_broadcast_at = key, now
            except Exception:
                log.exception("state loop")
            await asyncio.sleep(0.25)

    # =========================== state document ===========================
    def battery_view(self):
        s = self.stat
        fresh = self.stat_fresh()
        vbus = s.get("vbus_mv", -1) if fresh else -1
        voltage = round(vbus / 1000, 2) if vbus and vbus > 0 else None
        if voltage is None:
            if not self.esp["linkd"]:
                reason = "dorme-linkd is not running."
            elif not self.esp["up"]:
                reason = "No status from the motor controller (ESP32)."
            else:
                reason = "Voltage sensor (INA219) reading not available."
        else:
            reason = None
        under_load = self.motors_on() or (time.monotonic() - self.stopped_since) * 1000 < self.config["battery_settle_ms"]
        warn = self.config.get("low_battery_warn_mv")
        if warn is None or voltage is None:
            low = None
        elif not under_load:
            low = voltage * 1000 < warn
            self.low_latched = low
        else:
            low = self.low_latched
        return {"voltage_v": voltage, "voltage_reason": reason, "basis": "INA219 bus voltage at the logic rail",
                "age_ms": self.stat_age_ms() if voltage is not None else None, "under_load": under_load,
                "percent": None, "percent_reason": "Not calibrated. Needs the discharge log (bench test B22).",
                "low": low, "low_threshold_v": round(warn / 1000, 2) if warn else None,
                "low_basis": "simulated threshold" if (warn and self.mode == "simulator") else
                ("discharge log" if warn else "not calibrated"),
                "simulated": self.mode == "simulator"}

    def state(self):
        self.state_seq += 1
        s = self.stat
        fresh = self.stat_fresh()
        owner = self.arbiter.view()
        task = self.tasks.current
        moving = self.motors_on()
        direction = {"FF": "F", "RR": "B", "RF": "L", "FR": "R"}.get(s.get("dir")) if moving else None
        block = self.drive_block_reason()
        fault = self.esp_fault()
        esp_status = ("linkd_down" if not self.esp["linkd"] else
                      "up" if self.esp["up"] else "lost" if self.esp["ever_up"] else "never")
        sonar_cm = s.get("sonar_cm", -1) if fresh else -1
        if sonar_cm is not None and sonar_cm >= 0:
            sonar = {"status": "simulated" if self.mode == "simulator" else "available",
                     "distance_cm": sonar_cm, "reason": None}
        else:
            sonar = {"status": "unavailable", "distance_cm": None,
                     "reason": "No fresh controller status." if not fresh else "No echo / out of range."}
        cam = self.camera.status()
        cam.update(stream_path="/api/v1/camera/stream.mjpg" if self.camera.available() else None,
                   orientation="portrait", rotation_deg=self.config.get("camera_rotation_deg"),
                   rotation_verified=False)
        face_status = self.face.status()
        boot = self.esp["boot"] or {}
        return {
            "seq": self.state_seq,
            "robot": {"name": "DORM-E", "mode": self.mode, "simulated": self.mode == "simulator",
                      "software": api.SOFTWARE_VERSION, "api": api.API_VERSION, "bench_mode": self.bench,
                      "backend": self.link.name},
            "connection": {"esp32": esp_status, "esp_state": s.get("state") if fresh else None,
                           "stat_age_ms": self.stat_age_ms(), "hb_gap_max_ms": s.get("hb_gap_max_ms") if fresh else None,
                           "linkd_dry_run": self.esp["dry_run"], "firmware": boot.get("fw"),
                           "reset_reason": boot.get("reset_reason")},
            "battery": self.battery_view(),
            "motion": {"state": "moving" if moving else "stopped", "direction": direction,
                       "basis": "commanded", "owner": owner,
                       "outputs": "disabled_bench" if self.bench else "enabled",
                       "drive_allowed": block is None, "drive_block": block,
                       "drive_block_message": api.ACK_CODES.get(block) if block else None,
                       "last_stop": self.last_stop},
            "task": task.to_dict() if task else None,
            "fault": {"active": api.fault_info(fault), "last_off_forced": self.last_off_forced},
            "power": {"plug": bool(s.get("inputs", 0) & P.INPUT_GPIO34_HIGH) if fresh else None,
                      "shutting_down": self.off_reason, "motor_rail_on": bool(s.get("mot_en")) if fresh else None,
                      "motor_rail_v": round(s["vmot_mv"] / 1000, 1) if fresh and s.get("vmot_mv", -1) > 0 else None},
            "face": {"state": self.compute_face(), "adapter": face_status["status"],
                     "adapter_reason": face_status["reason"]},
            "peripherals": {"camera": cam, "audio": self.audio.status(), "ble": self.ble.status(), "sonar": sonar},
            "network": self.network_view(),
            "health": self.health_view(),
            "not_measured": list(api.NOT_MEASURED),
        }

    def health_items(self):
        return H.parts(self, self.vitals.data)

    def health_view(self):
        """Compact for the 1 Hz state: overall + issues + one short status per part id."""
        items = self.health_items()
        status, headline, issues = H.overall(items, self)
        return {"overall": status, "headline": headline,
                "issues": [{"id": i["id"], "status": i["status"], "text": i["text"]} for i in issues[:6]],
                "parts": {i["id"]: {"s": i["status"], "t": i["text"]} for i in items}}

    def network_view(self):
        v = self.vitals.data
        w, r = v.get("wifi") or {}, v.get("remote") or {}
        return {"trust": self.config["network_trust"], "wifi_ssid": w.get("ssid"), "wifi_dbm": w.get("signal_dbm"),
                "ipv4": w.get("ipv4") or [], "ethernet_ipv4": w.get("ethernet_ipv4") or [],
                "remote": {"online": bool(r.get("online")), "name": r.get("name"), "ips": r.get("ips") or [],
                           "state": r.get("state")}}

    def capabilities(self):
        c = self.config
        return {
            "api_version": api.API_VERSION,
            "commands": list(api.COMMANDS),
            "unauthenticated_commands": sorted(api.UNAUTHENTICATED_COMMANDS),
            "drive": {"directions": list(api.DIRECTIONS), "hold_to_drive": True,
                      "speed_levels_pct": [c["speed_low_pct"]], "turn_speed_pct": c["speed_turn_pct"],
                      "speed_note": "Phone speed is fixed at SPEED_LOW in V1. Firmware caps PWM at 60 %.",
                      "hold_lease_ms": c["hold_lease_ms"], "hold_interval_ms": c["hold_interval_ms"]},
            "tasks": self.tasks.catalog(),
            "battery": {"voltage": True, "percent": False, "basis": "INA219 bus voltage at the logic rail"},
            "camera": {"stream_path": "/api/v1/camera/stream.mjpg", "snapshot_path": "/api/v1/camera/snapshot.jpg",
                       "orientation": "portrait", "rotation_deg": c.get("camera_rotation_deg"),
                       "rotation_verified": False},
            "ble": {"service_uuid": api.BLE_SERVICE_UUID, "status_uuid": api.BLE_STATUS_UUID,
                    "setup_uuid": api.BLE_SETUP_UUID, "command_uuid": api.BLE_COMMAND_UUID},
            "staleness": {"stale_after_ms": api.STALE_AFTER_MS, "offline_after_ms": api.OFFLINE_AFTER_MS},
            "not_measured": list(api.NOT_MEASURED),
        }
