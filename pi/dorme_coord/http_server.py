"""App API over Wi-Fi: HTTP/1.1 + WebSocket (RFC 6455) + MJPEG, standard library only.

No third-party packages, so it runs on the Pi's system Python and on Windows for tests.
Plain HTTP/WS on the local network (declared deviation, spec section 8): driving is refused while
network_trust is "shared". Routes are listed in spec/API_V1.md.
"""
import asyncio
import base64
import hashlib
import json
import logging
import socket
import struct
import time
from urllib.parse import urlsplit

from . import api
from .provision import Provisioner
from .api import ack

log = logging.getLogger("dorme-coord.http")

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC11B85"
MAX_HEADER = 8192
MAX_BODY = 16384
MAX_WS_FRAME = 65536
WS_RATE_PER_S = 30
REASONS = {200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
           404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
           423: "Locked", 429: "Too Many Requests", 503: "Service Unavailable"}
ACK_HTTP_STATUS = {"UNAUTHORIZED": 401, "BAD_REQUEST": 400, "UNKNOWN_COMMAND": 404, "LOCKED_OUT": 423,
                   "BAD_PIN": 403, "RATE_LIMITED": 429, "UNAVAILABLE": 503}


class HttpError(Exception):
    def __init__(self, status, message=""):
        super().__init__(message)
        self.status = status


class Request:
    def __init__(self, method, target, headers, body, peer):
        self.method = method
        parts = urlsplit(target)
        self.path = parts.path
        self.query = dict(q.split("=", 1) for q in parts.query.split("&") if "=" in q)
        self.headers = headers
        self.body = body
        self.peer = peer

    def json(self):
        if not self.body:
            return {}
        try:
            data = json.loads(self.body)
        except ValueError:
            raise HttpError(400, "Body is not JSON")
        if not isinstance(data, dict):
            raise HttpError(400, "Body must be a JSON object")
        return data

    @property
    def is_loopback(self):
        host = (self.peer or ("",))[0]
        return host in ("127.0.0.1", "::1", "localhost")


class ApiServer:
    def __init__(self, coord, auth, host="0.0.0.0", port=8080, trust_loopback=False):
        self.coord = coord
        self.auth = auth
        self.provisioner = Provisioner(auth)
        self.host, self.port = host, port
        self.trust_loopback = trust_loopback
        self.server = None
        self._conn_counter = 0
        self.ws_clients = set()

    async def start(self):
        # 2026-11-25: "0.0.0.0" also listens on IPv6 ("::", v6-only). The robot announces IPv6 addresses over mDNS
        # (dorm-e.local), and a phone that picks one must not be refused.
        hosts = [self.host, "::"] if self.host == "0.0.0.0" and socket.has_ipv6 else self.host
        self.server = await asyncio.start_server(self._handle, hosts, self.port)
        self.port = self.server.sockets[0].getsockname()[1]
        log.info("API on http://%s:%s/api/v1/", self.host, self.port)
        return self.port

    async def close(self):
        if self.server:
            self.server.close()
            for ws in list(self.ws_clients):
                ws.close_now()
            await self.server.wait_closed()

    # ------------------------------------------------------------------ HTTP
    async def _read_request(self, reader, peer):
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
        if len(head) > MAX_HEADER:
            raise HttpError(413, "Headers too large")
        lines = head.decode("latin-1").split("\r\n")
        try:
            method, target, _version = lines[0].split(" ", 2)
        except ValueError:
            raise HttpError(400, "Bad request line")
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        length = int(headers.get("content-length", "0") or 0)
        if length > MAX_BODY:
            raise HttpError(413, "Body too large")
        body = await asyncio.wait_for(reader.readexactly(length), 10) if length else b""
        return Request(method.upper(), target, headers, body, peer)

    async def _handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        try:
            try:
                req = await self._read_request(reader, peer)
            except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
                return
            except HttpError as exc:
                await self._send_json(writer, exc.status, {"error": str(exc)})
                return
            try:
                await self._route(req, reader, writer)
            except HttpError as exc:
                await self._send_json(writer, exc.status, {"error": str(exc)})
        except (ConnectionError, asyncio.CancelledError):
            pass
        except Exception:
            log.exception("request failed")
            try:
                await self._send_json(writer, 500, {"error": "internal"})
            except Exception:
                pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _send(self, writer, status, body=b"", content_type="application/json", extra=None):
        headers = [f"HTTP/1.1 {status} {REASONS.get(status, 'Error')}", f"Content-Type: {content_type}",
                   f"Content-Length: {len(body)}", "Cache-Control: no-store", "Connection: close"]
        headers += extra or []
        writer.write(("\r\n".join(headers) + "\r\n\r\n").encode() + body)
        await writer.drain()

    async def _send_json(self, writer, status, obj):
        await self._send(writer, status, json.dumps(obj, separators=(",", ":")).encode())

    def _session(self, req):
        # 2026-11-25: Apple's URLSessionWebSocketTask does not send a URLRequest's Authorization header on the
        # upgrade (it is a header the URL Loading System reserves), so the app also sends X-DORME-Token; the
        # ?token= query form is a last resort for clients that cannot set headers.
        authz = req.headers.get("authorization", "")
        candidates = [authz[7:].strip()] if authz.lower().startswith("bearer ") else []
        candidates += [req.headers.get("x-dorme-token", "").strip(), req.query.get("token", "")]
        for token in candidates:
            sid = self.auth.check(token) if token else None
            if sid:
                return {"kind": "app", "id": "s-" + sid, "authenticated": True}
        if self.trust_loopback and req.is_loopback and "origin" not in req.headers:
            return {"kind": "local", "id": "local", "authenticated": True}
        peer = (req.peer or ("?",))[0]
        return {"kind": "app", "id": "anon-" + str(peer), "authenticated": False}

    def _require(self, source):
        if not source["authenticated"]:
            raise HttpError(401, "Pair first: POST /api/v1/pair")

    async def _command(self, writer, name, args, source, cid=None):
        reply = await self.coord.submit({"id": cid or f"http-{time.monotonic_ns()}", "name": name, "args": args}, source)
        status = 200 if reply["ok"] else ACK_HTTP_STATUS.get(reply["code"], 409)
        await self._send_json(writer, status, reply)

    async def _route(self, req, reader, writer):
        p, m = req.path.rstrip("/") or "/", req.method
        source = self._session(req)
        if p == "/api/v1/info" and m == "GET":
            st = self.coord.state()
            await self._send_json(writer, 200, {"name": "DORM-E", "api": api.API_VERSION,
                                                "software": api.SOFTWARE_VERSION, "mode": st["robot"]["mode"],
                                                "simulated": st["robot"]["simulated"],
                                                "paired": source["authenticated"], "pin_source": self.auth.pin_source})
        elif p == "/api/v1/pair" and m == "POST":
            body = req.json()
            token, code, wait_s = await self.auth.pair_async(str(body.get("pin", "")), body.get("client_name", "iPhone"))
            if not token:
                await self._send_json(writer, ACK_HTTP_STATUS[code], ack(None, False, code, result={"retry_after_s": wait_s}))
            else:
                if not self.auth.active_code():
                    self.coord.hide_pairing()     # the on-screen code was used (or had expired): clear the screen
                await self._send_json(writer, 200, ack(None, True, result={"token": token}))
        elif p == "/api/v1/pair/show" and m == "POST":
            # The code is drawn on the robot's own screen and never put in any reply: seeing the robot is the proof.
            if self.coord.face.status()["status"] not in ("ok", "simulated"):
                await self._send_json(writer, 503, ack(None, False, "UNAVAILABLE",
                                                       result={"reason": "The robot's screen is not available. Use the PIN."}))
            else:
                code, left_s, err, wait_s = self.auth.show_code()
                if not code:
                    await self._send_json(writer, ACK_HTTP_STATUS[err], ack(None, False, err, result={"retry_after_s": wait_s}))
                else:
                    self.coord.show_pairing(code, left_s, self.provisioner.qr_payload())
                    if self.coord.face.status()["status"] == "simulated":
                        print(f"SIMULATOR on-screen pairing code: {code}", flush=True)   # no real screen; protects nothing real
                    await self._send_json(writer, 200, ack(None, True, result={"expires_in_s": left_s,
                                                                                "shown_on": "robot_screen"}))
        elif p == "/api/v1/stop" and m == "POST":
            await self._command(writer, api.CMD_STOP, {}, source)        # no pairing needed, by design
        elif p == "/api/v1/commands" and m == "POST":
            body = req.json()
            await self._command(writer, body.get("name"), body.get("args") or {}, source, body.get("id"))
        elif p == "/api/v1/state" and m == "GET":
            self._require(source)
            await self._send_json(writer, 200, self.coord.state())
        elif p == "/api/v1/capabilities" and m == "GET":
            self._require(source)
            await self._send_json(writer, 200, self.coord.capabilities())
        elif p == "/api/v1/tasks" and m == "GET":
            self._require(source)
            await self._send_json(writer, 200, {"catalog": self.coord.tasks.catalog(), **self.coord.tasks.snapshot()})
        elif p == "/api/v1/tasks" and m == "POST":
            await self._command(writer, api.CMD_TASK_START, req.json(), source)
        elif p.startswith("/api/v1/tasks/") and p.endswith("/cancel") and m == "POST":
            await self._command(writer, api.CMD_TASK_CANCEL, {"task_id": p.split("/")[4]}, source)
        elif p == "/api/v1/faults/rearm" and m == "POST":
            await self._command(writer, api.CMD_FAULT_REARM, req.json(), source)
        elif p == "/api/v1/camera/snapshot.jpg" and m == "GET":
            self._require(source)
            await self._snapshot(writer)
        elif p == "/api/v1/camera/last.jpg" and m == "GET":
            self._require(source)
            if not self.coord.last_photo:
                raise HttpError(404, "No photo yet")
            await self._send(writer, 200, self.coord.last_photo, "image/jpeg")
        elif p == "/api/v1/camera/stream.mjpg" and m == "GET":
            self._require(source)
            await self._mjpeg(writer)
        elif p == "/api/v1/ws" and m == "GET":
            if not source["authenticated"]:
                log.warning("WebSocket upgrade refused (401): no valid token from %s; headers seen: %s",
                            (req.peer or ("?",))[0], sorted(k for k in req.headers if k != "authorization"))
            self._require(source)
            await self._websocket(req, reader, writer, source)
        elif p.startswith(("/api/v1/system", "/api/v1/network", "/api/v1/remote", "/api/v1/ble/")):
            await self._admin_route(p, m, req, writer, source)
        elif p.startswith("/api/v1/"):
            raise HttpError(404, "No such endpoint")
        else:
            raise HttpError(404, "DORM-E app API lives under /api/v1/")

    # ------------------------------------------------------------------ system, network, remote, BLE setup
    async def _admin_call(self, writer, op, **args):
        admin = self.coord.admin
        if admin is None:
            await self._send_json(writer, 503, ack(None, False, "UNAVAILABLE", "No admin helper on this robot."))
            return None
        reply = await admin.call(op, **args)
        if not reply.get("ok"):
            await self._send_json(writer, 409, ack(None, False, "UNAVAILABLE", reply.get("error") or "Refused."))
            return None
        return reply.get("result") or {}

    async def _admin_route(self, p, m, req, writer, source):
        loopback_only = p.startswith("/api/v1/ble/")
        if loopback_only:
            if not (req.is_loopback and "origin" not in req.headers):
                raise HttpError(403, "Bluetooth setup endpoints are local to the robot")
        else:
            self._require(source)
        if p == "/api/v1/system" and m == "GET":
            await self._send_json(writer, 200, {"parts": self.coord.health_items(), "vitals": self.coord.vitals.data,
                                                "network": self.coord.network_view()})
        elif p == "/api/v1/network/wifi" and m == "GET":
            status = await self._admin_call(writer, "wifi.status")
            if status is not None:
                saved = await self.coord.admin.call("wifi.saved")
                await self._send_json(writer, 200, dict(status, saved=(saved.get("result") or {}).get("saved", [])))
        elif p == "/api/v1/network/wifi/scan" and m == "GET":
            result = await self._admin_call(writer, "wifi.scan")
            if result is not None:
                await self._send_json(writer, 200, result)
        elif p == "/api/v1/network/wifi/result" and m == "GET":
            result = await self._admin_call(writer, "wifi.result")
            if result is not None:
                await self._send_json(writer, 200, result)
        elif p == "/api/v1/network/wifi" and m == "POST":
            body = req.json()
            args = {k: body[k] for k in ("ssid", "psk", "eap", "hidden", "priority", "connect", "force") if k in body}
            result = await self._admin_call(writer, "wifi.add", **args)
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        elif p == "/api/v1/network/wifi/forget" and m == "POST":
            body = req.json()
            result = await self._admin_call(writer, "wifi.forget", ssid=body.get("ssid"), force=bool(body.get("force")))
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        elif p == "/api/v1/system/restart" and m == "POST":
            result = await self._admin_call(writer, "service.restart", unit=req.json().get("unit"))
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        elif p in ("/api/v1/system/reboot", "/api/v1/system/poweroff") and m == "POST":
            if not req.json().get("confirm"):
                await self._send_json(writer, 409, ack(None, False, "CONFIRM_REQUIRED"))
                return
            result = await self._admin_call(writer, "system." + p.rsplit("/", 1)[1])
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        elif p == "/api/v1/remote/enable" and m == "POST":
            result = await self._admin_call(writer, "remote.up", timeout=40)
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        elif p == "/api/v1/ble/code" and m == "POST":
            code, left_s, err, wait_s = self.auth.show_code()
            if code:
                self.coord.show_pairing(code, left_s, self.provisioner.qr_payload())
            await self._send_json(writer, 200 if code else 423, ack(None, bool(code), None if code else err,
                                                                     result={"expires_in_s": left_s}))
        elif p == "/api/v1/ble/result" and m == "GET":
            result = await self._admin_call(writer, "wifi.result")
            if result is not None:
                await self._send_json(writer, 200, result)
        elif p == "/api/v1/ble/wifi" and m == "POST":
            try:
                blob = base64.b64decode(req.json().get("blob", ""), validate=True)
            except (ValueError, TypeError):
                raise HttpError(400, "blob must be base64")
            creds, err = self.provisioner.open_sealed(blob)
            if err:
                await self._send_json(writer, 403 if err == "BAD_PIN" else 409,
                                      ack(None, False, err if err in api.ACK_CODES else "BAD_REQUEST"))
                return
            self.coord.hide_pairing()
            args = {k: creds[k] for k in ("ssid", "psk", "eap", "hidden") if k in creds}
            result = await self._admin_call(writer, "wifi.add", connect=True, **args)
            if result is not None:
                await self._send_json(writer, 200, ack(None, True, result=result))
        else:
            raise HttpError(404, "No such endpoint")

    # ------------------------------------------------------------------ camera
    async def _snapshot(self, writer):
        cam = self.coord.camera
        if not cam.available():
            await self._send_json(writer, 503, {"error": cam.status().get("reason")})
            return
        try:
            frame = await asyncio.wait_for(cam.snapshot(), 8)
        except (RuntimeError, asyncio.TimeoutError):
            await self._send_json(writer, 503, {"error": "Camera did not deliver a frame."})
            return
        await self._send(writer, 200, frame, "image/jpeg")

    async def _mjpeg(self, writer):
        cam = self.coord.camera
        if not cam.available():
            await self._send_json(writer, 503, {"error": cam.status().get("reason")})
            return
        boundary = "dormeframe"
        writer.write((f"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary={boundary}\r\n"
                      "Cache-Control: no-store\r\nConnection: close\r\n\r\n").encode())
        try:
            async for frame in cam.frames():
                writer.write(f"--{boundary}\r\nContent-Type: image/jpeg\r\nContent-Length: {len(frame)}\r\n\r\n".encode()
                             + frame + b"\r\n")
                await writer.drain()
        except (ConnectionError, RuntimeError, asyncio.TimeoutError):
            pass

    # ------------------------------------------------------------------ WebSocket
    async def _websocket(self, req, reader, writer, source):
        h = req.headers
        log.info("WebSocket upgrade from %s: %s", (req.peer or ("?",))[0],
                 {k: v for k, v in h.items() if k not in ("authorization", "x-dorme-token", "cookie")})
        if h.get("upgrade", "").lower() != "websocket" or "sec-websocket-key" not in h:
            raise HttpError(400, "Expected a WebSocket upgrade")
        if h.get("sec-websocket-version") != "13":
            raise HttpError(400, "WebSocket version 13 required")
        origin = h.get("origin")
        if origin and urlsplit(origin).netloc != h.get("host"):
            log.warning("WebSocket refused (403): origin %r host %r", origin, h.get("host"))
            raise HttpError(403, "Cross-origin WebSocket refused")
        accept = base64.b64encode(hashlib.sha1((h["sec-websocket-key"] + WS_GUID).encode()).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {accept}\r\n\r\n").encode())
        await writer.drain()
        self._conn_counter += 1
        client_source = dict(source, id=f"{source['id']}#ws{self._conn_counter}")
        ws = WebSocketConn(reader, writer)
        self.ws_clients.add(ws)
        queue = asyncio.Queue(maxsize=200)

        def listener(msg):
            if queue.full():
                ws.close_now()      # slow client: drop it rather than buffer without bound
                return
            queue.put_nowait(msg)

        self.coord.add_listener(listener)
        sender = asyncio.get_running_loop().create_task(self._ws_sender(ws, queue))
        try:
            await ws.send_json({"v": api.API_VERSION, "type": "hello", "client": client_source["id"],
                                "state": self.coord.state(), "capabilities": self.coord.capabilities()})
            bucket, bucket_at = WS_RATE_PER_S, time.monotonic()
            while True:
                text = await ws.receive_text(timeout=15)
                if text is None:
                    break
                now = time.monotonic()
                bucket = min(WS_RATE_PER_S, bucket + (now - bucket_at) * WS_RATE_PER_S)
                bucket_at = now
                try:
                    msg = json.loads(text)
                except ValueError:
                    await ws.send_json(ack(None, False, "BAD_REQUEST"))
                    continue
                if not isinstance(msg, dict) or msg.get("type") != "command":
                    await ws.send_json(ack(msg.get("id") if isinstance(msg, dict) else None, False, "BAD_REQUEST"))
                    continue
                if bucket < 1 and msg.get("name") != api.CMD_STOP:     # stop is never rate limited
                    await ws.send_json(ack(msg.get("id"), False, "RATE_LIMITED"))
                    continue
                bucket -= 1
                reply = await self.coord.submit(msg, client_source)
                await ws.send_json(reply)
        except (ConnectionError, asyncio.IncompleteReadError, asyncio.TimeoutError, WsClosed):
            pass
        finally:
            self.coord.remove_listener(listener)
            sender.cancel()
            self.ws_clients.discard(ws)
            await self.coord.client_gone(client_source["kind"], client_source["id"])
            ws.close_now()

    async def _ws_sender(self, ws, queue):
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(queue.get(), 5)
                    await ws.send_json(msg)
                except asyncio.TimeoutError:
                    await ws.ping()
        except (ConnectionError, WsClosed, asyncio.CancelledError):
            pass


class WsClosed(Exception):
    pass


class WebSocketConn:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.lock = asyncio.Lock()
        self.closed = False

    async def _send_frame(self, opcode, payload):
        if self.closed:
            raise WsClosed()
        n = len(payload)
        if n < 126:
            header = struct.pack("!BB", 0x80 | opcode, n)
        elif n < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 126, n)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 127, n)
        async with self.lock:
            self.writer.write(header + payload)
            await self.writer.drain()

    async def send_json(self, obj):
        await self._send_frame(0x1, json.dumps(obj, separators=(",", ":")).encode())

    async def ping(self):
        await self._send_frame(0x9, b"dorme")

    async def receive_text(self, timeout=15):
        """Next text message, or None on close. Pings are answered; pongs only refresh the timer."""
        while True:
            head = await asyncio.wait_for(self.reader.readexactly(2), timeout)
            b1, b2 = head
            fin, opcode, masked, length = b1 & 0x80, b1 & 0x0F, b2 & 0x80, b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            if not masked or length > MAX_WS_FRAME or not fin:
                await self._close(1002 if not masked else 1009)
                return None
            mask = await self.reader.readexactly(4)
            data = bytearray(await self.reader.readexactly(length))
            for i in range(length):
                data[i] ^= mask[i % 4]
            if opcode == 0x8:
                await self._close(1000)
                return None
            if opcode == 0x9:
                await self._send_frame(0xA, bytes(data))
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x1:
                return data.decode("utf-8", "replace")
            await self._close(1003)
            return None

    async def _close(self, code):
        try:
            await self._send_frame(0x8, struct.pack("!H", code))
        except (WsClosed, ConnectionError):
            pass
        self.closed = True

    def close_now(self):
        self.closed = True
        try:
            self.writer.close()
        except Exception:
            pass
