"""Pi <-> ESP32 line protocol (spec section 2).

Frame: $DE,<TYPE>,<seq>,<fields>*<CC>\\n
CC = CRC-8, poly 0x07, init 0, over the bytes between '$' and '*', two uppercase hex digits.
Maximum 128 bytes including the newline. Token frames (HALTED/REBOOT) carry no seq or CRC.
Missing values: '-' for text, -1 for numbers.
"""
from dataclasses import dataclass, field

MAX_FRAME = 128
PROTO_VERSION = 1

# Field names per frame type, in wire order. Integers are converted on parse.
PI_TO_ESP = {
    "HELLO": ("proto", "nonce"),
    "HB": ("move_id", "pi_ready"),
    "MOVE": ("move_id", "kind", "dur_ms", "speed_pct", "src"),
    "DRV": ("move_id", "left_pct", "right_pct", "src"),
    "STOP": ("reason",),
    "REARM": ("src",),
    "OFF_ACK": ("reason",),
    "SVC": ("minutes",),
    "PROG": ("move_id", "marker_id"),
}
ESP_TO_PI = {
    "BOOT": ("proto", "fw", "reset_reason", "flags"),
    "HELLO_ACK": ("nonce",),
    "STAT": ("state", "fault", "vbus_mv", "vbus_age_ms", "vmot_mv", "inputs", "mot_en",
             "pwm_l", "pwm_r", "dir", "sonar_cm", "move_id", "on_ms", "hb_gap_max_ms", "uptime_s"),
    "MOVE_ACK": ("move_id", "granted_ms", "granted_pct"),
    "MOVE_NAK": ("move_id", "reason"),
    "MOVE_DONE": ("move_id", "reason", "on_ms"),
    "OFF_REQ": ("reason",),
    "FAULT": ("code", "detail"),
    "REARM_OK": ("detail",),
    "REARM_NAK": ("reason",),
    "OFFLOG": ("reason", "ms_to_ack", "ms_to_token", "fs", "forced"),
}
ALL_TYPES = {**PI_TO_ESP, **ESP_TO_PI}

INT_FIELDS = {
    "proto", "move_id", "pi_ready", "dur_ms", "speed_pct", "left_pct", "right_pct", "minutes",
    "marker_id", "vbus_mv", "vbus_age_ms", "vmot_mv", "inputs", "mot_en", "pwm_l", "pwm_r",
    "sonar_cm", "on_ms", "hb_gap_max_ms", "uptime_s", "granted_ms", "granted_pct",
    "ms_to_ack", "ms_to_token", "forced",
}
HEX_FIELDS = {"flags"}

STATES = ("BOOT", "WAIT_LINK", "CHECK", "ARMING", "READY", "MOVING", "FAULT",
          "OFF_WAIT_ACK", "OFF_WAIT_TOKEN", "SETTLE", "CUT", "NOCUT")
INPUT_GPIO32_HIGH, INPUT_GPIO34_HIGH, INPUT_GPIO39_HIGH = 1, 2, 4
BOOT_FLAG_NOCUT, BOOT_FLAG_FORCED, BOOT_FLAG_OFFLOG = 1, 2, 4
BOOT_FLAG_RTC_WDT_MISSING = 8      # firmware could not arm its RTC watchdog backstop

REARMABLE = {"STALE", "JAM", "LOW_BUS", "ESP_RESET", "INA_FAIL", "RAIL_DEAD", "NOCUT"}
VOICE_REARMABLE = REARMABLE - {"NOCUT"}


def crc8(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


class FrameError(ValueError):
    pass


@dataclass
class Frame:
    type: str
    seq: int = -1
    fields: dict = field(default_factory=dict)
    token: bool = False

    def __getitem__(self, key):
        return self.fields[key]

    def get(self, key, default=None):
        return self.fields.get(key, default)


def _text(value) -> str:
    if value is None:
        return "-"
    text = str(value)
    if any(c in text for c in ",*$\r\n") or not text.isprintable():
        raise FrameError(f"Illegal character in field {text!r}")
    return text


def encode(ftype: str, seq: int, *values) -> bytes:
    """Build one framed line. values follow the field order for ftype."""
    if ftype not in ALL_TYPES:
        raise FrameError(f"Unknown frame type {ftype}")
    expected = ALL_TYPES[ftype]
    if len(values) != len(expected):
        raise FrameError(f"{ftype} needs {len(expected)} fields, got {len(values)}")
    if not 0 <= seq <= 65535:
        raise FrameError("seq out of range")
    parts = ["DE", ftype, str(seq)]
    for name, value in zip(expected, values):
        if name in HEX_FIELDS and isinstance(value, int):
            parts.append(format(value, "X"))
        elif isinstance(value, bool):
            parts.append("1" if value else "0")
        elif isinstance(value, int):
            parts.append(str(value))
        else:
            parts.append(_text(value))
    body = ",".join(parts)
    line = f"${body}*{crc8(body.encode()):02X}\n".encode()
    if len(line) > MAX_FRAME:
        raise FrameError("Frame longer than 128 bytes")
    return line


def encode_token(kind: str, nonce: str, fs: str) -> bytes:
    if kind not in ("HALTED", "REBOOT") or fs not in ("ro", "rw"):
        raise FrameError("Bad token frame")
    return f"$DE,{kind},{_text(nonce)},{fs}\n".encode()


def _convert(name: str, raw: str):
    if name in HEX_FIELDS:
        return int(raw, 16)
    if name in INT_FIELDS:
        return int(raw)
    return None if raw == "-" else raw


def decode(line) -> Frame:
    """Parse one line (bytes or str, with or without newline). Raises FrameError."""
    if isinstance(line, bytes):
        if len(line) > MAX_FRAME:
            raise FrameError("Frame too long")
        try:
            line = line.decode("ascii")
        except UnicodeDecodeError as exc:
            raise FrameError("Non-ASCII frame") from exc
    elif len(line.encode("ascii", "replace")) > MAX_FRAME:
        raise FrameError("Frame too long")
    line = line.rstrip("\r\n")
    if not line.startswith("$DE,"):
        raise FrameError("Not a DE frame")
    parts = line[1:].split(",")
    if len(parts) == 4 and parts[1] in ("HALTED", "REBOOT") and "*" not in line:
        if parts[3] not in ("ro", "rw"):
            raise FrameError("Bad token filesystem flag")
        return Frame(parts[1], fields={"nonce": parts[2], "fs": parts[3]}, token=True)
    if line.count("*") != 1:
        raise FrameError("Missing or repeated checksum marker")
    body, cc = line[1:].split("*")
    if len(cc) != 2 or any(c not in "0123456789ABCDEFabcdef" for c in cc):
        raise FrameError("Bad checksum digits")
    if crc8(body.encode()) != int(cc, 16):
        raise FrameError("Checksum mismatch")
    parts = body.split(",")
    if len(parts) < 3 or parts[0] != "DE":
        raise FrameError("Short frame")
    ftype = parts[1]
    if ftype not in ALL_TYPES:
        raise FrameError(f"Unknown frame type {ftype}")
    try:
        seq = int(parts[2])
    except ValueError as exc:
        raise FrameError("Bad seq") from exc
    if not 0 <= seq <= 65535:
        raise FrameError("seq out of range")
    names = ALL_TYPES[ftype]
    values = parts[3:]
    if len(values) != len(names):
        raise FrameError(f"{ftype} expects {len(names)} fields, got {len(values)}")
    try:
        fields = {name: _convert(name, raw) for name, raw in zip(names, values)}
    except ValueError as exc:
        raise FrameError(f"Bad number in {ftype}") from exc
    return Frame(ftype, seq, fields)


class LineSplitter:
    """Accumulates raw serial bytes; yields complete lines; drops oversize garbage."""

    def __init__(self):
        self.buffer = bytearray()
        self.dropped = 0

    def feed(self, data: bytes):
        self.buffer.extend(data)
        lines = []
        while True:
            index = self.buffer.find(b"\n")
            if index < 0:
                if len(self.buffer) > 4 * MAX_FRAME:
                    # ROM boot text or noise without newlines: discard but keep a tail.
                    self.dropped += 1
                    del self.buffer[:-MAX_FRAME]
                return lines
            line = bytes(self.buffer[:index + 1])
            del self.buffer[:index + 1]
            start = line.rfind(b"$DE,")
            if start > 0:
                self.dropped += 1  # leading noise before a frame on the same line
                line = line[start:]
            lines.append(line)


class SeqCounter:
    def __init__(self):
        self.value = 0

    def next(self) -> int:
        current = self.value
        self.value = (self.value + 1) % 65536
        return current
