"""Link backends: how the coordinator reaches the ESP32.

Both expose the same two calls, using dorme-linkd's own JSON request/event vocabulary
(dorme_robot/dorme/linkd.py) so the coordinator cannot tell them apart:

    await backend.request({"cmd": "stop" | "ready" | "move" | "hold" | "release" | "rearm" | "state", ...})
    backend.on_event = callback   # receives {"t": "link"|"esp"|"stopped"|"off"|"dry_run"|"linkd", ...}

LinkdBackend  - HARDWARE. Talks to the real, unmodified dorme-linkd over /run/dorme/link.sock.
                linkd stays the sole owner of the serial port (spec section 1).
FrameBackend  - SIMULATOR (or a future direct port). Speaks the serial frames itself, with the
                same heartbeat / hold / STOP-repeat rules as linkd, to a byte transport such as
                SimTransport(Esp32Sim). Never used with real hardware in this build.
"""
import asyncio
import json
import logging
import secrets
import time

from .legacy import protocol as P

log = logging.getLogger("dorme-coord.link")


def monotonic_ms():
    return int(time.monotonic() * 1000)


class LinkBackend:
    name = "base"

    def __init__(self):
        self.on_event = lambda event: None

    def emit(self, event):
        try:
            self.on_event(event)
        except Exception:  # never let a listener break the link loop
            log.exception("link event handler failed")

    async def start(self):
        raise NotImplementedError

    async def request(self, obj):
        raise NotImplementedError

    async def close(self):
        pass


# ----------------------------------------------------------------------------------------------
class LinkdBackend(LinkBackend):
    """Client of the existing dorme-linkd. `connect` returns (reader, writer); by default a Unix
    socket. Tests inject a TCP connector because Windows has no Unix sockets in asyncio."""
    name = "linkd"

    def __init__(self, sock_path="/run/dorme/link.sock", connect=None, timeout=1.0):
        super().__init__()
        self.sock_path = sock_path
        self.timeout = timeout
        self._connect = connect or (lambda: asyncio.open_unix_connection(str(sock_path)))
        self._task = None
        self.connected = False

    async def start(self):
        self._task = asyncio.get_running_loop().create_task(self._subscribe_loop())

    async def close(self):
        if self._task:
            self._task.cancel()

    async def _subscribe_loop(self):
        while True:
            try:
                reader, writer = await asyncio.wait_for(self._connect(), self.timeout)
                writer.write(b'{"cmd":"subscribe"}\n')
                await writer.drain()
                first = True
                while True:
                    line = await reader.readline()
                    if not line:
                        break
                    event = json.loads(line)
                    if first:
                        first = False
                        self.connected = True
                        self.emit({"t": "linkd", "up": True})
                    self.emit(event)
            except (OSError, ConnectionError, ValueError, asyncio.TimeoutError) as exc:
                log.debug("linkd subscribe: %s", exc)
            except asyncio.CancelledError:
                raise
            if self.connected:
                self.connected = False
                self.emit({"t": "linkd", "up": False})
            await asyncio.sleep(1.0)

    async def request(self, obj):
        try:
            reader, writer = await asyncio.wait_for(self._connect(), self.timeout)
        except (OSError, asyncio.TimeoutError) as exc:
            return {"ok": False, "error": f"linkd unavailable ({exc.__class__.__name__})"}
        try:
            writer.write(json.dumps(obj, separators=(",", ":")).encode() + b"\n")
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), self.timeout)
            return json.loads(line) if line else {"ok": False, "error": "linkd closed"}
        except (OSError, ValueError, asyncio.TimeoutError) as exc:
            return {"ok": False, "error": f"linkd request failed ({exc.__class__.__name__})"}
        finally:
            writer.close()


# ----------------------------------------------------------------------------------------------
class SimTransport:
    """Couples a FrameBackend to an in-process Esp32Sim. Runs the sim's 10 ms loop."""

    def __init__(self, sim):
        self.sim = sim
        self.on_bytes = lambda data: None
        self._task = None

    def write(self, data: bytes):
        self.sim.feed(data)
        return True

    async def start(self):
        self._task = asyncio.get_running_loop().create_task(self._loop())

    async def _loop(self):
        while True:
            self.sim.tick()
            data = self.sim.take_output()
            if data:
                self.on_bytes(data)
            await asyncio.sleep(0.01)

    async def close(self):
        if self._task:
            self._task.cancel()


class FrameBackend(LinkBackend):
    """A small linkd twin for the simulator: same rules, same events, no serial port, no poweroff."""
    name = "frames"

    def __init__(self, transport, config):
        super().__init__()
        self.t = transport
        self.config = config
        self.seq = P.SeqCounter()
        self.splitter = P.LineSplitter()
        self.nonce = secrets.token_hex(4).upper()
        self.link_up = False
        self.ever_up = False
        self.last_stat_ms = 0
        self.last_stat = None
        self.boot = None
        self.pi_ready = False
        self.move_id = 0
        self._next_move = 1
        self.hold = None
        self.stop_pending = None
        self.sent = []               # (type, fields) of every frame sent, for tests
        self._task = None

    # ----- plumbing -----
    def send(self, ftype, *values):
        self.sent.append((ftype, values))
        return self.t.write(P.encode(ftype, self.seq.next(), *values))

    def _on_bytes(self, data):
        for line in self.splitter.feed(data):
            try:
                frame = P.decode(line)
            except P.FrameError:
                continue
            self.handle(frame)

    async def start(self):
        self.t.on_bytes = self._on_bytes
        await self.t.start()
        self.send("HELLO", P.PROTO_VERSION, self.nonce)
        self._task = asyncio.get_running_loop().create_task(self._tick_loop())
        self.emit({"t": "linkd", "up": True})

    async def close(self):
        if self._task:
            self._task.cancel()
        await self.t.close()

    def _set_link(self, up):
        if up != self.link_up:
            self.link_up = up
            self.ever_up = self.ever_up or up
            self.emit({"t": "link", "up": up})

    def handle(self, frame):
        f = frame.fields
        if frame.type == "BOOT":
            self.boot = dict(f)
            self.move_id = 0
            self.hold = None            # a reset ESP32 must never be asked to resume anything
            self.send("HELLO", P.PROTO_VERSION, self.nonce)
        elif frame.type == "STAT":
            self.last_stat, self.last_stat_ms = f, monotonic_ms()
            self._set_link(True)
            if self.stop_pending and f["pwm_l"] == 0 and f["pwm_r"] == 0:
                self.emit({"t": "stopped", "reason": self.stop_pending})
                self.stop_pending = None
        elif frame.type in ("MOVE_DONE", "MOVE_NAK"):
            if f["move_id"] == self.move_id:
                self.move_id = 0
            if self.hold and f["move_id"] == self.hold["move_id"]:
                self.hold = None
        elif frame.type == "OFF_REQ":
            self.send("OFF_ACK", f["reason"])
            self.emit({"t": "off", "reason": f["reason"]})
        self.emit({"t": "esp", "type": frame.type, **f})

    def new_move_id(self):
        value = self._next_move
        self._next_move = self._next_move % 65535 + 1
        return value

    def stop(self, reason):
        self.hold = None
        self.move_id = 0
        self.stop_pending = reason
        self.send("STOP", reason)

    async def _tick_loop(self):
        period = self.config["heartbeat_ms"] / 1000
        while True:
            now = monotonic_ms()
            if self.hold:
                if now > self.hold["deadline_ms"]:
                    self.stop("P")
                elif not self.stop_pending:
                    h = self.hold
                    self.send("DRV", h["move_id"], h["left"], h["right"], h["src"])
            if self.stop_pending:
                self.send("STOP", self.stop_pending)
            self.send("HB", self.move_id, 1 if self.pi_ready else 0)
            if self.link_up and now - self.last_stat_ms > self.config["link_lost_ms"]:
                self._set_link(False)
            await asyncio.sleep(period)

    # ----- linkd-compatible requests -----
    async def request(self, req):
        cmd = req.get("cmd")
        if cmd == "state":
            return {"ok": True, "link_up": self.link_up, "ever_up": self.ever_up, "stat": self.last_stat,
                    "boot": self.boot, "dry_run": False, "move_id": self.move_id}
        if cmd == "stop":
            self.stop(req.get("reason", "S"))
            return {"ok": True, "link_up": self.link_up}
        if cmd == "ready":
            self.pi_ready = bool(req.get("value"))
            return {"ok": True}
        if not self.link_up and cmd in ("move", "hold"):
            return {"ok": False, "error": "link down"}
        if cmd == "move":
            move_id = self.new_move_id()
            self.move_id = move_id
            self.send("MOVE", move_id, req["kind"], int(req["dur_ms"]), int(req["speed_pct"]), req.get("src", "P"))
            return {"ok": True, "move_id": move_id}
        if cmd == "hold":
            kind = req["kind"]
            s, t = self.config["speed_low_pct"], self.config["speed_turn_pct"]
            left, right = {"F": (s, s), "B": (-s, -s), "L": (-t, t), "R": (t, -t)}[kind]
            if self.hold and self.hold["kind"] != kind:
                self.stop("P")    # direction change: STOP first, new move id after PWM 0
            if not self.hold or self.hold["kind"] != kind:
                self.hold = {"kind": kind, "move_id": self.new_move_id(), "left": left, "right": right, "src": "P"}
            self.hold["deadline_ms"] = monotonic_ms() + int(self.config["link_hold_ms"])
            return {"ok": True, "move_id": self.hold["move_id"]}
        if cmd == "release":
            if self.hold:
                self.stop("P")
            return {"ok": True}
        if cmd == "rearm":
            self.send("REARM", req.get("src", "P"))
            return {"ok": True}
        return {"ok": False, "error": f"unknown cmd {cmd}"}
