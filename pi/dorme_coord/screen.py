"""The owner's screen settings (2026-11-26): face style and colour, the resting screen and uploaded pictures.

Folder (hardware): /var/lib/dorme-face, created by dorme-face's StateDirectory (group dorme-face, 0775), so this
coordinator (SupplementaryGroups=dorme-face) writes and the face (dorme_robot/face/face.py) reads:
  settings.json            {"face": {"style", "color"}, "resting": <screen> | null}
  screen/<sha256-32>.png   480x320 pictures the app uploaded (drawings, text it rendered)
The face re-reads settings.json when it changes and saves splash.rgb565 there for the next power-on.

A <screen> is {"bg": [r, g, b], "layers": [...]} as documented in face.py (clean_screen). Everything here is
validated again by the face, which never trusts the file.
"""
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path

STYLES = ("classic", "round", "tall", "wide", "calm", "happy")     # face.py STYLES; FaceRenderer.swift
FONTS = ("clean", "bold", "serif", "mono")
FILE_RE = re.compile(r"^[0-9a-f]{32}\.png$")
MAX_PNG = 1_500_000
MAX_LAYERS = 4
TEXT_MAX = 80
MAX_SECONDS = 24 * 3600
KEEP_FILES = 24
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _rgb(value, name):
    if value is None:
        return None
    if not (isinstance(value, list) and len(value) == 3 and all(type(x) is int and 0 <= x <= 255 for x in value)):
        raise ValueError(f"{name} must be [r, g, b] with 0-255 integers")
    return list(value)


def _unit(value, default=0.5):
    if value is None:
        return default
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("x and y must be numbers 0-1")
    return min(0.9, max(0.1, float(value)))


class ScreenStore:
    def __init__(self, folder, create=False):
        self.dir = Path(folder)
        self.create = create
        if create:
            (self.dir / "screen").mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ status
    def status(self):
        if not self.dir.is_dir():
            return {"status": "unavailable",
                    "reason": "No /var/lib/dorme-face yet. Install the face update (dorme-face StateDirectory)."}
        if not os.access(self.dir, os.W_OK):
            return {"status": "no_permission", "reason": "Coordinator cannot write /var/lib/dorme-face."}
        return {"status": "ok", "reason": None}

    def available(self):
        return self.status()["status"] == "ok"

    # ------------------------------------------------------------------ files
    def save_png(self, data):
        """Stores an uploaded picture. Returns its file name (content hash), or raises ValueError."""
        if not isinstance(data, (bytes, bytearray)) or not data.startswith(PNG_SIG):
            raise ValueError("Not a PNG")
        if len(data) > MAX_PNG:
            raise ValueError("Picture too large")
        try:
            from PIL import Image
            import io
            with Image.open(io.BytesIO(data)) as im:
                if im.size != (480, 320):
                    raise ValueError("Picture must be 480 x 320")
                im.verify()
        except ImportError:
            pass
        except ValueError:
            raise
        except Exception as exc:
            raise ValueError(f"Unreadable PNG ({exc.__class__.__name__})")
        name = hashlib.sha256(data).hexdigest()[:32] + ".png"
        folder = self.dir / "screen"
        folder.mkdir(exist_ok=True)
        path = folder / name
        if not path.exists():
            self._atomic(path, bytes(data))
            self.gc(keep={name})
        return name

    def has(self, name):
        return bool(FILE_RE.match(name)) and (self.dir / "screen" / name).is_file()

    def gc(self, keep=()):
        """Deletes the oldest pictures nobody uses, keeping KEEP_FILES."""
        folder = self.dir / "screen"
        if not folder.is_dir():
            return
        used = set(keep) | self._referenced(self.settings().get("resting"))
        files = sorted((p for p in folder.iterdir() if FILE_RE.match(p.name) and p.name not in used),
                       key=lambda p: p.stat().st_mtime, reverse=True)
        for p in files[KEEP_FILES:]:
            try:
                p.unlink()
            except OSError:
                pass

    @staticmethod
    def _referenced(content):
        return {layer["file"] for layer in (content or {}).get("layers", []) if layer.get("kind") == "image"}

    # ------------------------------------------------------------------ settings
    def settings(self):
        try:
            data = json.loads((self.dir / "settings.json").read_text())
            if isinstance(data, dict):
                face = data.get("face") if isinstance(data.get("face"), dict) else {}
                return {"face": {"style": face.get("style") if face.get("style") in STYLES else "classic",
                                 "color": face.get("color")},
                        "resting": data.get("resting") if isinstance(data.get("resting"), dict) else None}
        except (OSError, ValueError):
            pass
        return {"face": {"style": "classic", "color": None}, "resting": None}

    def set_face(self, style, color):
        if style not in STYLES:
            raise ValueError("style must be one of " + ", ".join(STYLES))
        data = self.settings()
        data["face"] = {"style": style, "color": _rgb(color, "color")}
        self._write(data)
        return data["face"]

    def set_resting(self, content):
        data = self.settings()
        data["resting"] = content
        self._write(data)

    def clean(self, args):
        """Validates a screen from the app or voice: {"bg", "layers"}. Returns the clean screen."""
        layers = args.get("layers")
        if not isinstance(layers, list) or not 1 <= len(layers) <= MAX_LAYERS:
            raise ValueError(f"layers: 1 to {MAX_LAYERS}")
        out = []
        for layer in layers:
            if not isinstance(layer, dict):
                raise ValueError("each layer is an object")
            blink = layer.get("blink", False)
            if not isinstance(blink, bool):
                raise ValueError("blink must be true or false")
            if layer.get("kind") == "image":
                name = layer.get("file")
                if not isinstance(name, str) or not self.has(name):
                    raise ValueError("unknown picture: upload it first (POST /api/v1/screen/image)")
                out.append({"kind": "image", "file": name, "blink": blink})
            elif layer.get("kind") == "text":
                text = layer.get("text")
                if not isinstance(text, str) or not text.strip():
                    raise ValueError("text layer needs text")
                text = " ".join(text.split())
                if len(text) > TEXT_MAX:
                    raise ValueError(f"text: up to {TEXT_MAX} characters")
                font = layer.get("font", "clean")
                if font not in FONTS:
                    raise ValueError("font must be one of " + ", ".join(FONTS))
                out.append({"kind": "text", "text": text, "font": font,
                            "color": _rgb(layer.get("color"), "color") or [245, 245, 247],
                            "x": _unit(layer.get("x")), "y": _unit(layer.get("y")), "blink": blink})
            else:
                raise ValueError("layer kind must be image or text")
        return {"bg": _rgb(args.get("bg"), "bg") or [0, 0, 0], "layers": out}

    # ------------------------------------------------------------------ io
    def _write(self, data):
        self._atomic(self.dir / "settings.json", json.dumps(data, separators=(",", ":")).encode())

    @staticmethod
    def _atomic(path, data):
        fd, temp = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temp, 0o664)
            os.replace(temp, path)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)


def summary(content):
    """A few words for the app: what the screen shows."""
    if not content:
        return None
    texts = [layer["text"] for layer in content.get("layers", []) if layer.get("kind") == "text"]
    if texts:
        return texts[0][:40]
    return "Your drawing"
