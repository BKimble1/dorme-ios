"""Adapter for the face that already runs on the Pi (dorme_pi_bootstrap/face.py, unit dorme-face).

That face reads /run/dorme-face/state.json = {"state": <name>, "expires_at": <unix s or 0>} and
returns to idle after expires_at. This adapter writes the same file the same way `dormectl face`
does: temp file in the same folder, then os.replace (atomic on POSIX and Windows). It never
creates /run/dorme-face (dorme-face's RuntimeDirectory) and never touches the face code, service,
display driver or boot configuration.

Every non-idle state is written with an expiry and refreshed while it holds, so if the
coordinator dies the face drifts back to idle by itself instead of freezing in, say, "fault".
"""
import json
import os
import tempfile
import time
from pathlib import Path

from .api import BOOTSTRAP_FACE_STATES

REFRESH_S = 2.0
HOLD_S = 6.0

# Coordinator face names -> states the installed bootstrap face can draw.
# The bootstrap face has no "moving" look; "listening" (wider eyes) is the closest. Approximation.
FACE_MAP = {
    "idle": "idle", "listening": "listening", "moving": "listening", "happy": "happy",
    "puzzled": "puzzled", "low_energy": "low_energy", "sleepy": "sleepy", "fault": "fault",
    "pairing": "pairing",   # 2026-11-25: big on-screen one-time code (needs the face with the "pairing" state)
    "note": "note",         # 2026-11-26: owner's message + countdown (face state "note", fields text/until)
}


class FaceAdapter:
    def __init__(self, state_dir, create_dir=False, clock=time.time):
        self.dir = Path(state_dir)
        self.path = self.dir / "state.json"
        self.create_dir = create_dir      # True only for the simulator's private folder
        self.clock = clock
        self.last_written = None
        self.last_code = None
        self.last_note = None
        self.last_write_at = 0.0
        self.writes = 0
        self.error = None

    def status(self):
        if self.create_dir:
            return {"status": "simulated", "reason": "Simulator writes to its own folder, not a display."}
        if not self.dir.is_dir():
            return {"status": "unavailable", "reason": "dorme-face is not running (no /run/dorme-face)."}
        if not os.access(self.dir, os.W_OK):
            return {"status": "no_permission",
                    "reason": "Coordinator cannot write /run/dorme-face. See docs/DEPLOY.md, face access."}
        if self.error:
            return {"status": "error", "reason": self.error}
        return {"status": "ok", "reason": None}

    def set(self, name, transient_s=None, code=None, qr=None, note=None):
        """Write the face state if it changed (or needs a refresh). Returns True if written.
        code: six digits shown by the "pairing" state only."""
        state = FACE_MAP.get(name, "idle")
        assert state in BOOTSTRAP_FACE_STATES
        if state == "pairing" and not (isinstance(code, str) and code.isdigit() and len(code) == 6):
            state, code = "idle", None
        if state != "pairing":
            code = qr = None
        if qr is not None and not (isinstance(qr, str) and len(qr) <= 200):
            qr = None
        if state == "note" and not (isinstance(note, dict) and note.get("text")):
            state = "idle"
        if state != "note":
            note = None
        now = self.clock()
        if state == "idle":
            if self.last_written in (None, "idle"):
                return False             # never overwrite a manual `dormectl face` with idle at start
            expires = 0
        else:
            if (state == self.last_written and code == self.last_code and note == self.last_note
                    and transient_s is None and now - self.last_write_at < REFRESH_S):
                return False
            expires = now + (transient_s if transient_s is not None else HOLD_S)
        data = {"state": state, "expires_at": expires, "source": "dorme-coordinator"}
        if code:
            data["code"] = code
        if qr:
            data["qr"] = qr
        if note:
            data["text"] = note["text"]
            if note.get("until"):
                data["until"] = note["until"]
        written = self._write(data, state, now)
        if written:
            self.last_code, self.last_note = code, note
        return written

    def _write(self, data, state, now):
        if self.create_dir:
            self.dir.mkdir(parents=True, exist_ok=True)
        if not self.dir.is_dir():
            return False
        try:
            fd, temp = tempfile.mkstemp(prefix=".state-", dir=self.dir)
            try:
                with os.fdopen(fd, "w") as handle:
                    json.dump(data, handle)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(temp, 0o640 if "code" in data else 0o644)   # a live pairing code: owner + face group only
                os.replace(temp, self.path)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
        except OSError as exc:
            self.error = f"write failed: {exc.__class__.__name__}"
            return False
        self.error = None
        self.last_written, self.last_write_at = state, now
        self.writes += 1
        return True
