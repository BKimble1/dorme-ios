"""Camera, audio and BLE status with truthful availability.

Each service reports one of: available / detected / advertising (real hardware answered),
simulated (synthetic, labelled), unavailable (with the reason). Nothing here claims a device
works because it is on the parts list.
"""
import asyncio
import io
import json
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path


# =============================== camera ===============================
class JpegSplitter:
    """Splits a byte stream of concatenated JPEGs (rpicam-vid --codec mjpeg -o -) into frames."""

    def __init__(self, max_frame=2_000_000):
        self.buf = bytearray()
        self.max_frame = max_frame

    def feed(self, data):
        self.buf.extend(data)
        frames = []
        while True:
            start = self.buf.find(b"\xff\xd8")
            if start < 0:
                self.buf.clear()
                return frames
            if start > 0:
                del self.buf[:start]
            end = self.buf.find(b"\xff\xd9", 2)
            if end < 0:
                if len(self.buf) > self.max_frame:
                    self.buf.clear()
                return frames
            frames.append(bytes(self.buf[:end + 2]))
            del self.buf[:end + 2]


class CameraService:
    kind = "none"

    def __init__(self, reason="No camera configured."):
        self.reason = reason
        self.subscribers = 0

    def status(self):
        return {"status": "unavailable", "reason": self.reason}

    def available(self):
        return self.status()["status"] in ("available", "simulated")

    async def frames(self):
        raise RuntimeError(self.reason)
        yield b""  # pragma: no cover

    async def snapshot(self):
        async for frame in self.frames():
            return frame
        raise RuntimeError("no frame")


class SimCamera(CameraService):
    """Synthetic portrait test card, clearly marked SIMULATED. Needs Pillow."""
    kind = "simulated"

    def __init__(self, fps=4):
        super().__init__()
        self.fps = fps
        try:
            from PIL import Image, ImageDraw  # noqa: F401
            self._ok = True
        except ImportError:
            self._ok = False
            self.reason = "Pillow is not installed, so the simulator cannot draw test frames."

    def status(self):
        if not self._ok:
            return {"status": "unavailable", "reason": self.reason}
        return {"status": "simulated", "reason": "Synthetic test frames. No real camera."}

    def render(self, t):
        from PIL import Image, ImageDraw
        w, h = 360, 480
        img = Image.new("RGB", (w, h), (236, 232, 224))
        d = ImageDraw.Draw(img)
        for i, c in enumerate([(220, 90, 70), (240, 180, 60), (90, 170, 110), (70, 120, 200), (130, 90, 180)]):
            d.rectangle((i * w // 5, 0, (i + 1) * w // 5, 60), fill=c)
        x = int((w - 60) * (0.5 + 0.45 * __import__("math").sin(t * 1.3)))
        d.ellipse((x, 200, x + 60, 260), fill=(30, 30, 30))
        d.rectangle((0, h - 70, w, h), fill=(20, 20, 20))
        d.text((14, h - 58), "SIMULATED CAMERA", fill=(255, 255, 255))
        d.text((14, h - 34), time.strftime("%H:%M:%S") + "  no real image", fill=(200, 200, 200))
        out = io.BytesIO()
        img.save(out, "JPEG", quality=70)
        return out.getvalue()

    async def frames(self):
        if not self._ok:
            raise RuntimeError(self.reason)
        self.subscribers += 1
        try:
            while True:
                yield self.render(time.monotonic())
                await asyncio.sleep(1 / self.fps)
        finally:
            self.subscribers -= 1


class RpiCamera(CameraService):
    """OV5647 through rpicam-vid MJPEG. UNTESTED on DORM-E: the camera has not been fitted/run.
    The picture is portrait (sensor turned 90 deg in A03); rpicam cannot rotate 90, so frames are
    sent unrotated and `rotation_deg` (unknown until the bench test) tells the app how to turn them."""
    kind = "rpicam"

    def __init__(self, width=640, height=480, fps=8):
        super().__init__()
        self.width, self.height, self.fps = width, height, fps
        self._probe_at = 0.0
        self._probe = None
        self._proc = None
        self._latest = None
        self._cond = asyncio.Condition()
        self._reader = None

    def _do_probe(self):
        if not sys.platform.startswith("linux"):
            return {"status": "unavailable", "reason": "Not a Raspberry Pi."}
        tool = shutil.which("rpicam-hello") or shutil.which("libcamera-hello")
        if not shutil.which("rpicam-vid"):
            return {"status": "unavailable", "reason": "rpicam-apps is not installed."}
        try:
            out = subprocess.run([tool, "--list-cameras"], capture_output=True, text=True, timeout=8)
            text = out.stdout + out.stderr
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"status": "unavailable", "reason": f"Camera probe failed ({exc.__class__.__name__})."}
        if "No cameras available" in text or ":" not in text.split("Available cameras")[-1]:
            return {"status": "unavailable", "reason": "No camera detected on the CSI port."}
        model = "ov5647" if "ov5647" in text.lower() else "unknown sensor"
        return {"status": "available", "reason": None, "sensor": model}

    def status(self):
        """Cached; the probe (rpicam-hello, up to 8 s) runs in a thread so it never stalls the event loop
        (2026-11-26 build audit: it used to block drive holds and the stop path every 30 s)."""
        import threading
        now = time.monotonic()
        if (self._probe is None or now - self._probe_at > 30) and not getattr(self, "_probing", False):
            self._probing, self._probe_at = True, now

            def probe():
                try:
                    self._probe = self._do_probe()
                finally:
                    self._probing = False
            if sys.platform.startswith("linux"):
                threading.Thread(target=probe, daemon=True).start()
            else:
                probe()
        return dict(self._probe or {"status": "unavailable", "reason": "Checking for a camera."})

    async def _run(self):
        cmd = ["rpicam-vid", "-t", "0", "--codec", "mjpeg", "--width", str(self.width),
               "--height", str(self.height), "--framerate", str(self.fps), "--nopreview", "-o", "-"]
        self._proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE,
                                                          stderr=asyncio.subprocess.DEVNULL)
        splitter = JpegSplitter()
        try:
            while True:
                chunk = await self._proc.stdout.read(65536)
                if not chunk:
                    break
                for frame in splitter.feed(chunk):
                    async with self._cond:
                        self._latest = frame
                        self._cond.notify_all()
                if self.subscribers == 0:
                    break
        finally:
            if self._proc.returncode is None:
                self._proc.terminate()
            self._proc = None
            self._reader = None

    async def frames(self):
        if not self.available():
            raise RuntimeError(self.status()["reason"])
        self.subscribers += 1
        try:
            if self._reader is None:
                self._reader = asyncio.get_running_loop().create_task(self._run())
            while True:
                async with self._cond:
                    await asyncio.wait_for(self._cond.wait(), 5)
                    frame = self._latest
                yield frame
        finally:
            self.subscribers -= 1


# =============================== audio ===============================
class AudioService:
    """Detects the U16 USB audio card by name. Playback is not wired to the coordinator yet:
    sounds still belong to dorme-audio (dorme_robot), which follows dorme-core's events."""

    def __init__(self, card_match="USB", cards_path="/proc/asound/cards", simulated=False):
        self.card_match = card_match
        self.cards_path = Path(cards_path)
        self.simulated = simulated

    def status(self):
        if self.simulated:
            return {"status": "unavailable", "reason": "The simulator has no audio device.",
                    "playback": "not_connected"}
        try:
            text = self.cards_path.read_text()
        except OSError:
            return {"status": "unavailable", "reason": "No ALSA sound cards on this computer.",
                    "playback": "not_connected"}
        for line in text.splitlines():
            if self.card_match.lower() in line.lower() and "[" in line:
                return {"status": "detected", "reason": "Card found; playback not connected to the coordinator yet.",
                        "card": line.strip()[:80], "playback": "not_connected"}
        return {"status": "unavailable", "reason": f"No sound card matching '{self.card_match}'.",
                "playback": "not_connected"}


# =============================== BLE ===============================
class BleStatus:
    """Reads the status file the BLE bridge (ble_bridge.py) writes while it advertises."""

    def __init__(self, status_file="/run/dorme/ble.json", simulated=False):
        self.path = Path(status_file)
        self.simulated = simulated

    def status(self):
        if self.simulated:
            return {"status": "unavailable", "reason": "The simulator does not advertise over Bluetooth."}
        if not sys.platform.startswith("linux"):
            return {"status": "unavailable", "reason": f"No BlueZ on {platform.system()}."}
        try:
            data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {"status": "not_running", "reason": "dorme-ble bridge is not running."}
        age = time.time() - float(data.get("updated_at", 0))
        if age > 10:
            return {"status": "not_running", "reason": "dorme-ble bridge stopped reporting."}
        return {"status": data.get("state", "unknown"), "reason": data.get("reason")}
