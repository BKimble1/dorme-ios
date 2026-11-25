"""Task lifecycle: pending -> running -> succeeded | failed | cancelled.

One task at a time. Stop cancels every task. A task that uses motion owns the motion arbiter for
its whole run, so the app cannot drive at the same time. History is persisted, but a task that
was running when the coordinator stopped is recorded as failed ("not resumed"): nothing restarts
by itself after a reboot or reconnect.
"""
import asyncio
import collections
import json
import logging
import secrets
import time
from pathlib import Path

from .api import TASK_TERMINAL

log = logging.getLogger("dorme-coord.tasks")

CATALOG = [
    {"action": "greet", "title": "Say hello", "symbol": "hand.wave",
     "detail": "Happy face for a moment. No movement.", "uses_motion": False},
    {"action": "self_check", "title": "Self check", "symbol": "checklist",
     "detail": "Checks each subsystem and reports only what it can actually measure.", "uses_motion": False},
    {"action": "move_forward_short", "title": "Short move forward", "symbol": "arrow.up",
     "detail": "One bounded forward move at the slow speed. Firmware clips and can refuse it.",
     "uses_motion": True, "kind": "F"},
    {"action": "turn_left_short", "title": "Short turn left", "symbol": "arrow.counterclockwise",
     "detail": "One short pivot. Turning capability is not established.", "uses_motion": True, "kind": "L"},
    {"action": "turn_right_short", "title": "Short turn right", "symbol": "arrow.clockwise",
     "detail": "One short pivot. Turning capability is not established.", "uses_motion": True, "kind": "R"},
    {"action": "take_photo", "title": "Take a photo", "symbol": "camera",
     "detail": "One still from the head camera.", "uses_motion": False, "needs": "camera"},
    {"action": "go_to_desk", "title": "Go to desk", "symbol": "map",
     "detail": "Drive to a marked spot.", "uses_motion": True, "needs": "navigation"},
]
CATALOG_BY_ACTION = {entry["action"]: entry for entry in CATALOG}


class TaskCancelled(Exception):
    pass


class Task:
    def __init__(self, action, source):
        entry = CATALOG_BY_ACTION[action]
        self.id = f"t-{int(time.time()) % 100000:05d}-{secrets.token_hex(2)}"
        self.action = action
        self.title = entry["title"]
        self.uses_motion = entry["uses_motion"]
        self.state = "pending"
        self.progress = 0.0
        self.step = "Waiting to start"
        self.source = source
        self.created_at = time.time()
        self.started_mono = None
        self.ended_at = None
        self.result = {}
        self.error = None
        self.bench = False
        self.runner = None

    def to_dict(self):
        return {"id": self.id, "action": self.action, "title": self.title, "state": self.state,
                "progress": round(self.progress, 3) if self.progress is not None else None,
                "step": self.step, "source": self.source, "uses_motion": self.uses_motion,
                "bench": self.bench, "created_at": round(self.created_at, 3),
                "ended_at": round(self.ended_at, 3) if self.ended_at else None,
                "elapsed_ms": int((time.monotonic() - self.started_mono) * 1000) if self.started_mono and not self.ended_at else None,
                "result": self.result, "error": self.error}


class TaskManager:
    def __init__(self, coord, state_dir=None):
        self.coord = coord
        self.current = None
        self.history = collections.deque(maxlen=20)
        self.path = Path(state_dir) / "task_history.json" if state_dir else None
        self._load()

    # ----- persistence -----
    def _load(self):
        if not self.path:
            return
        try:
            items = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return
        for item in items[-20:]:
            if item.get("state") not in TASK_TERMINAL:
                item["state"] = "failed"
                item["error"] = {"code": "INTERNAL", "message": "Coordinator restarted during this task; not resumed."}
            self.history.append(item)

    def _save(self):
        if not self.path:
            return
        from .util import atomic_write_json
        try:
            atomic_write_json(self.path, list(self.history))
        except OSError as exc:
            log.warning("task history not saved: %s", exc)

    # ----- catalog -----
    def availability(self, action):
        """-> (available, code, reason)."""
        entry = CATALOG_BY_ACTION.get(action)
        if not entry:
            return False, "BAD_REQUEST", "Unknown task."
        needs = entry.get("needs")
        if needs == "navigation":
            return False, "UNAVAILABLE", "Needs marker navigation, which is not built yet."
        if needs == "camera" and not self.coord.camera.available():
            return False, "UNAVAILABLE", self.coord.camera.status().get("reason") or "No camera."
        if entry["uses_motion"]:
            block = self.coord.drive_block_reason()
            if block:
                return False, block, None
        return True, None, None

    def catalog(self):
        out = []
        for entry in CATALOG:
            ok, code, reason = self.availability(entry["action"])
            out.append({"action": entry["action"], "title": entry["title"], "detail": entry["detail"],
                        "symbol": entry["symbol"], "uses_motion": entry["uses_motion"],
                        "available": ok, "unavailable_code": code, "unavailable_reason": reason})
        return out

    def snapshot(self):
        return {"current": self.current.to_dict() if self.current else None,
                "history": list(reversed(self.history))[:10]}

    # ----- lifecycle -----
    def start(self, action, source):
        """-> (ok, code, message, task_dict)."""
        if self.current and self.current.state not in TASK_TERMINAL:
            return False, "TASK_ACTIVE", None, None
        ok, code, reason = self.availability(action)
        if not ok:
            return False, code, reason, None
        task = Task(action, source)
        task.bench = bool(self.coord.bench and task.uses_motion)
        if task.uses_motion:
            claimed, code, _ = self.coord.arbiter.claim("task", task.id, lease_ms=None)
            if not claimed:
                return False, code, None, None
        self.current = task
        task.runner = asyncio.get_running_loop().create_task(self._run(task))
        self.coord.emit_event("task.updated", task=task.to_dict())
        return True, None, None, task.to_dict()

    async def cancel(self, reason="Cancelled", task_id=None):
        task = self.current
        if not task or task.state in TASK_TERMINAL or (task_id and task.id != task_id):
            return False
        self._finish(task, "cancelled", error={"code": "CANCELLED", "message": reason})
        if task.runner and not task.runner.done():
            task.runner.cancel()
            try:
                await task.runner
            except (asyncio.CancelledError, Exception):
                pass
        return True

    def _finish(self, task, state, result=None, error=None):
        if task.state in TASK_TERMINAL:
            return
        task.state = state
        task.ended_at = time.time()
        if result:
            task.result.update(result)
        task.error = error
        if state == "succeeded":
            task.progress = 1.0
            task.step = "Done"
        elif state == "cancelled":
            task.step = "Cancelled"
        else:
            task.step = "Failed"
        if task.uses_motion:
            self.coord.arbiter.release("task", task.id)
        self.history.append(task.to_dict())
        self._save()
        self.coord.emit_event("task.updated", task=task.to_dict())
        self.coord.on_task_finished(task)

    def progress(self, task, value, step=None):
        if task.state in TASK_TERMINAL:
            raise TaskCancelled()
        task.progress = max(0.0, min(1.0, value))
        if step:
            task.step = step
        self.coord.emit_event("task.updated", task=task.to_dict())

    async def _run(self, task):
        task.state = "running"
        task.started_mono = time.monotonic()
        task.step = "Starting"
        self.coord.emit_event("task.updated", task=task.to_dict())
        try:
            impl = getattr(self, "_do_" + task.action, None)
            if impl is None:
                kind = CATALOG_BY_ACTION[task.action].get("kind")
                result = await self._do_bounded_move(task, kind)
            else:
                result = await impl(task)
            self._finish(task, "succeeded", result=result)
        except TaskCancelled:
            pass
        except asyncio.CancelledError:
            self._finish(task, "cancelled", error={"code": "CANCELLED", "message": "Cancelled"})
        except TaskFailed as exc:
            self._finish(task, "failed", error={"code": exc.code, "message": exc.message})
        except Exception as exc:  # pragma: no cover - defensive
            log.exception("task %s crashed", task.action)
            self._finish(task, "failed", error={"code": "INTERNAL", "message": str(exc)[:120]})

    async def _sleep_progress(self, task, seconds, start, end, step):
        steps = max(1, int(seconds / 0.2))
        for i in range(steps):
            await asyncio.sleep(seconds / steps)
            self.progress(task, start + (end - start) * (i + 1) / steps, step)

    # ----- task bodies -----
    async def _do_greet(self, task):
        self.coord.face_transient("happy", 2.5)
        await self._sleep_progress(task, 2.5, 0.0, 1.0, "Smiling")
        audio = self.coord.audio.status()
        return {"summary": "Showed the happy face.",
                "note": "No chime: audio playback is not connected to the coordinator yet."
                if audio.get("playback") != "connected" else None}

    async def _do_self_check(self, task):
        c = self.coord
        checks = []
        state = c.state()

        def add(name, status, detail):
            checks.append({"name": name, "status": status, "detail": detail})

        add("Coordinator", "ok", f"Software {state['robot']['software']}, {state['robot']['mode']} mode.")
        face = state["face"]
        add("Face display", "ok" if face["adapter"] in ("ok", "simulated") else "unavailable", face["adapter_reason"] or face["adapter"])
        esp = state["connection"]["esp32"]
        add("Motor controller link", "ok" if esp == "up" else "unavailable",
            {"up": f"ESP32 in {state['connection']['esp_state']}.", "never": "No ESP32 has answered since start.",
             "lost": "ESP32 stopped answering.", "linkd_down": "dorme-linkd is not running."}.get(esp, esp))
        b = state["battery"]
        add("Battery voltage", "ok" if b["voltage_v"] is not None else "unavailable",
            f"{b['voltage_v']:.2f} V at the logic rail{' (simulated)' if b['simulated'] else ''}."
            if b["voltage_v"] is not None else b["voltage_reason"])
        s = state["peripherals"]["sonar"]
        add("Sonar", "ok" if s["status"] in ("available", "simulated") else "unavailable",
            f"{s['distance_cm']} cm" if s["distance_cm"] is not None else s["reason"])
        for key, label in (("camera", "Camera"), ("audio", "Audio"), ("ble", "Bluetooth")):
            p = state["peripherals"][key]
            add(label, "ok" if p["status"] in ("available", "detected", "advertising", "simulated") else "unavailable",
                p.get("reason") or p["status"])
        add("Motor outputs", "warn" if state["motion"]["outputs"] == "disabled_bench" else "ok",
            "Disabled (bench mode)." if state["motion"]["outputs"] == "disabled_bench" else "Enabled.")
        for i, check in enumerate(checks):
            await asyncio.sleep(0.35)
            self.progress(task, (i + 1) / len(checks), f"Checked {check['name'].lower()}")
        ok = sum(1 for ch in checks if ch["status"] == "ok")
        return {"summary": f"{ok} of {len(checks)} subsystems answered.", "checks": checks}

    async def _do_take_photo(self, task):
        self.progress(task, 0.2, "Capturing")
        try:
            jpeg = await asyncio.wait_for(self.coord.camera.snapshot(), 10)
        except (RuntimeError, asyncio.TimeoutError) as exc:
            raise TaskFailed("UNAVAILABLE", f"Camera did not deliver a frame ({exc.__class__.__name__}).")
        self.coord.last_photo = jpeg
        self.progress(task, 0.9, "Saving")
        return {"summary": "Photo taken.", "url": "/api/v1/camera/last.jpg", "bytes": len(jpeg),
                "simulated": self.coord.camera.kind == "simulated"}

    async def _do_bounded_move(self, task, kind):
        c = self.coord
        dur = int(c.config["move_ms"][kind])
        speed = c.config["speed_turn_pct"] if kind in "LR" else c.config["speed_low_pct"]
        if c.bench:
            await self._sleep_progress(task, dur / 1000, 0.0, 1.0, "Bench rehearsal (no motor output)")
            return {"summary": "Bench rehearsal finished.", "note": "Bench mode: no motor output was sent.",
                    "requested_ms": dur, "speed_pct": speed}
        reply = await c.link.request({"cmd": "move", "kind": kind, "dur_ms": dur, "speed_pct": speed, "src": "P"})
        if not reply.get("ok"):
            raise TaskFailed("LINK_DOWN", reply.get("error") or "Move not sent.")
        if reply.get("dry_run"):
            await self._sleep_progress(task, dur / 1000, 0.0, 1.0, "linkd dry run (logged, not sent)")
            return {"summary": "linkd is in dry_run: the move was logged, not sent.", "requested_ms": dur}
        move_id = reply["move_id"]
        queue = c.watch_move(move_id)
        try:
            granted = None
            deadline = time.monotonic() + dur / 1000 + 2.0
            while True:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    await c.link.request({"cmd": "stop", "reason": "C"})
                    raise TaskFailed("INTERNAL", "No MOVE_DONE from the controller; stop sent.")
                try:
                    ev = await asyncio.wait_for(queue.get(), min(timeout, 0.2))
                except asyncio.TimeoutError:
                    if granted:
                        elapsed = time.monotonic() - granted[0]
                        self.progress(task, min(0.99, elapsed * 1000 / max(1, granted[1])), "Moving (commanded)")
                    continue
                if ev["type"] == "MOVE_ACK":
                    granted = (time.monotonic(), ev["granted_ms"])
                    task.result.update(granted_ms=ev["granted_ms"], granted_pct=ev["granted_pct"])
                    self.progress(task, 0.05, "Moving (commanded)")
                elif ev["type"] == "MOVE_NAK":
                    raise TaskFailed("MOVE_REFUSED", f"Controller refused: {ev['reason']}.")
                elif ev["type"] == "MOVE_DONE":
                    if ev["reason"] == "TIME":
                        return {"summary": "Move finished on time (commanded, not measured).", "on_ms": ev["on_ms"]}
                    raise TaskFailed("MOVE_REFUSED", f"Move ended early: {ev['reason']}.")
        finally:
            c.unwatch_move(move_id)


class TaskFailed(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message
