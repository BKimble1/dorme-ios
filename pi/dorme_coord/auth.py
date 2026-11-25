"""PIN pairing and bearer sessions for the app API.

PIN source, in order:
1. The existing dorme-web PIN store (pin_file, default /var/lib/dorme/web.json: pin_salt + pin_hash,
   PBKDF2-SHA256 200k, written by dorme_robot/tools/make_label.py). Read only, so the printed
   label's PIN also pairs the app.
2. Otherwise the coordinator's own auth.json in state_dir. If it has no PIN, one is generated:
   hardware mode never prints it (read it with `sudo cat <state_dir>/pin.txt`); simulator mode
   prints it to the console because it protects nothing real.

Sessions: random 32-byte tokens; only their SHA-256 is stored. 5 wrong PINs lock pairing for 60 s,
doubling each time (spec section 8, AUTH).

On-screen code (2026-11-25): show_code() makes a random 6-digit one-time code, valid CODE_TTL_S, that the
robot draws on its own face screen. It is never sent over the network and never written to disk. It pairs
once, then it is gone. Wrong guesses count towards the same lockout as wrong PINs.
"""
import hashlib
import hmac
import json
import os
import secrets
import time
from pathlib import Path

from .util import atomic_write_json

MAX_SESSIONS = 8
CODE_TTL_S = 120


def pin_hash(pin, salt_hex):
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt_hex), 200_000).hex()


class Auth:
    def __init__(self, state_dir, pin_file=None, simulator=False, clock=time.monotonic, announce=print):
        self.state_dir = Path(state_dir)
        self.path = self.state_dir / "auth.json"
        self.clock = clock
        self.failures = 0
        self.locked_until = 0.0
        self.lock_s = 60
        self.code = None            # (six digits, expires at self.clock()) while an on-screen code is live
        self.data = self._load()
        external = self._load_external(pin_file)
        if external:
            self.pin_salt, self.pin_hash, self.pin_source = external["pin_salt"], external["pin_hash"], "dorme-web label"
        else:
            if not self.data.get("pin_hash"):
                pin = "".join(secrets.choice("0123456789") for _ in range(6))
                salt = secrets.token_hex(16)
                self.data.update(pin_salt=salt, pin_hash=pin_hash(pin, salt))
                self._save()
                if simulator:
                    announce(f"SIMULATOR pairing PIN: {pin}")
                else:
                    pin_txt = self.state_dir / "pin.txt"
                    pin_txt.write_text(pin + "\n")
                    try:
                        os.chmod(pin_txt, 0o600)
                    except OSError:
                        pass
                    announce(f"New pairing PIN written to {pin_txt} (root only). Not printed.")
            self.pin_salt, self.pin_hash, self.pin_source = self.data["pin_salt"], self.data["pin_hash"], "coordinator"

    def _load(self):
        try:
            data = json.loads(self.path.read_text())
            return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    @staticmethod
    def _load_external(pin_file):
        if not pin_file:
            return None
        try:
            data = json.loads(Path(pin_file).read_text())
            if data.get("pin_hash") and data.get("pin_salt"):
                return data
        except (OSError, ValueError, AttributeError):
            pass
        return None

    def _save(self):
        atomic_write_json(self.path, self.data, mode=0o600)

    def set_pin(self, pin):
        if not (isinstance(pin, str) and pin.isdigit() and 6 <= len(pin) <= 8):
            raise ValueError("PIN must be 6 to 8 digits")
        salt = secrets.token_hex(16)
        self.data.update(pin_salt=salt, pin_hash=pin_hash(pin, salt), sessions={})
        self.pin_salt, self.pin_hash, self.pin_source = salt, self.data["pin_hash"], "coordinator"
        self._save()

    async def pair_async(self, pin, client_name="iPhone"):
        """pair() with the slow PBKDF2 off the event loop, so stop/lease handling never stalls."""
        import asyncio
        now = self.clock()
        if now < self.locked_until:
            return None, "LOCKED_OUT", int(self.locked_until - now) + 1
        digest = await asyncio.get_running_loop().run_in_executor(
            None, pin_hash, pin if isinstance(pin, str) else "", self.pin_salt)
        return self.pair(pin, client_name, digest=digest)

    def show_code(self):
        """Start (or keep) the on-screen one-time code. -> (code, seconds_left, None, None) or
        (None, None, "LOCKED_OUT", retry_after_s). The caller draws the code on the robot's screen only."""
        now = self.clock()
        if now < self.locked_until:
            return None, None, "LOCKED_OUT", int(self.locked_until - now) + 1
        if not self.active_code(now):
            self.code = ("".join(secrets.choice("0123456789") for _ in range(6)), now + CODE_TTL_S)
        return self.code[0], int(self.code[1] - now), None, None

    def active_code(self, now=None):
        now = self.clock() if now is None else now
        if self.code and now >= self.code[1]:
            self.code = None
        return self.code[0] if self.code else None

    def cancel_code(self):
        self.code = None

    def note_failure(self, now=None):
        """One wrong PIN or code. 5 in a row lock pairing for lock_s, doubling each time."""
        now = self.clock() if now is None else now
        self.failures += 1
        if self.failures >= 5:
            self.failures = 0
            self.locked_until = now + self.lock_s
            self.lock_s *= 2

    def pair(self, pin, client_name="iPhone", digest=None):
        """-> (token, None, None) or (None, code, retry_after_s) with code LOCKED_OUT / BAD_PIN.
        Accepts the stored PIN or the live on-screen code (which is then used up)."""
        now = self.clock()
        if now < self.locked_until:
            return None, "LOCKED_OUT", int(self.locked_until - now) + 1
        live = self.active_code(now)
        if live and isinstance(pin, str) and hmac.compare_digest(pin.encode(), live.encode()):
            self.code = None
            ok = True
        else:
            if digest is None and isinstance(pin, str):
                digest = pin_hash(pin, self.pin_salt)
            ok = isinstance(pin, str) and hmac.compare_digest(digest, self.pin_hash)
        if not ok:
            self.note_failure(now)
            return None, "BAD_PIN", None
        self.failures, self.lock_s = 0, 60
        token = secrets.token_urlsafe(32)
        sessions = self.data.setdefault("sessions", {})
        sid = secrets.token_hex(4)
        sessions[sid] = {"hash": hashlib.sha256(token.encode()).hexdigest(), "name": str(client_name)[:40],
                         "created_at": time.time()}
        while len(sessions) > MAX_SESSIONS:
            oldest = min(sessions, key=lambda k: sessions[k]["created_at"])
            del sessions[oldest]
        self._save()
        return f"{sid}.{token}", None, None

    def check(self, bearer):
        """-> session id or None."""
        if not bearer or "." not in bearer:
            return None
        sid, token = bearer.split(".", 1)
        entry = self.data.get("sessions", {}).get(sid)
        if not entry:
            return None
        if hmac.compare_digest(entry["hash"], hashlib.sha256(token.encode()).hexdigest()):
            return sid
        return None

    def revoke(self, sid):
        if self.data.get("sessions", {}).pop(sid, None):
            self._save()
