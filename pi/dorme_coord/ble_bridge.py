"""dorme-ble: Pi Bluetooth LE peripheral for nearby discovery, setup and basic status.

UNTESTED ON HARDWARE. Written against BlueZ's documented D-Bus GATT API (the pattern of BlueZ's
test/example-gatt-server) and needs python3-dbus and python3-gi, which Raspberry Pi OS normally
ships. It is a separate process so a BlueZ problem cannot stall the coordinator.

GATT service DORM-E (UUIDs in api.py):
  status  read/notify  compact JSON <= 180 bytes, refreshed every 2 s from the coordinator
  setup   read         how to reach the Wi-Fi API: {"v":1,"port":8080,"addrs":[...],"bonjour":"_dorme._tcp"}
  command write        "STOP" -> POST /api/v1/stop;  "CODE" -> robot screen shows the pairing code + QR
  wifi    write        sealed Wi-Fi details (provision.py), sent as chunks: byte 0 = index << 1 | last
  result  read/notify  {"ok": true/false/null, "ssid", "ipv4", "message"} after a Wi-Fi setup

Nothing here can drive the robot. Wi-Fi details only open with the token from the robot's on-screen QR.
Run: sudo python3 -m dorme_coord.ble_bridge [--api http://127.0.0.1:8080]
"""
import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.request

from . import api
from .util import atomic_write_json


def status_payload(state, max_bytes=api.BLE_MAX_PAYLOAD):
    """Compact status for the BLE status characteristic. Shrinks until it fits max_bytes."""
    b = state.get("battery", {})
    task = state.get("task") or {}
    fault = (state.get("fault") or {}).get("active") or {}
    full = {
        "v": api.API_VERSION,
        "n": state.get("robot", {}).get("name", "DORM-E"),
        "sim": 1 if state.get("robot", {}).get("simulated") else 0,
        "bv": b.get("voltage_v"),                       # volts at the logic rail, or null
        "esp": state.get("connection", {}).get("esp32"),
        "mo": state.get("motion", {}).get("state"),
        "bench": 1 if state.get("robot", {}).get("bench_mode") else 0,
        "f": fault.get("code"),
        "t": task.get("action") if task.get("state") in ("pending", "running") else None,
        "tp": task.get("progress") if task.get("state") == "running" else None,
        "s": state.get("seq"),
        "w": (state.get("network") or {}).get("wifi_ssid"),
        "ip": ((state.get("network") or {}).get("ipv4") or [None])[0],
        "h": (state.get("health") or {}).get("overall"),
    }
    for drop in (None, "tp", "t", "s", "sim", "h"):
        if drop:
            full.pop(drop, None)
        data = json.dumps(full, separators=(",", ":")).encode()
        if len(data) <= max_bytes:
            return data
    return json.dumps({"v": api.API_VERSION, "f": full.get("f"), "mo": full.get("mo")}, separators=(",", ":")).encode()


def setup_payload(port, addrs):
    data = {"v": api.API_VERSION, "port": port, "addrs": addrs[:3], "bonjour": api.BONJOUR_TYPE}
    out = json.dumps(data, separators=(",", ":")).encode()
    while len(out) > api.BLE_MAX_PAYLOAD and data["addrs"]:
        data["addrs"].pop()
        out = json.dumps(data, separators=(",", ":")).encode()
    return out


def local_addresses():
    addrs = []
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in addrs:
                addrs.append(ip)
    except OSError:
        pass
    return addrs


def fetch_state(base):
    with urllib.request.urlopen(base + "/api/v1/state", timeout=2) as resp:
        return json.loads(resp.read())


def post_json(base, path, body):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read())
        except ValueError:
            return {"ok": False, "code": str(exc.code)}


def get_json(base, path):
    with urllib.request.urlopen(base + path, timeout=4) as resp:
        return json.loads(resp.read())


class ChunkAssembler:
    """Reassembles framed writes: byte 0 = index << 1 | last-flag, rest = data. Index restarts at 0."""

    def __init__(self, limit=1024):
        self.parts, self.limit = [], limit

    def feed(self, data):
        if not data:
            return None
        index, last = data[0] >> 1, data[0] & 1
        if index == 0:
            self.parts = []
        if index != len(self.parts):
            self.parts = []
            return None
        self.parts.append(bytes(data[1:]))
        if sum(len(p) for p in self.parts) > self.limit:
            self.parts = []
            return None
        if last:
            blob, self.parts = b"".join(self.parts), []
            return blob
        return None


def send_stop(base):
    req = urllib.request.Request(base + "/api/v1/stop", data=b"{}", method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=2) as resp:
        return json.loads(resp.read())


def main():  # pragma: no cover - needs BlueZ
    parser = argparse.ArgumentParser(description="DORM-E BLE bridge (untested on hardware)")
    parser.add_argument("--api", default="http://127.0.0.1:8080")
    parser.add_argument("--status-file", default="/run/dorme/ble.json")
    parser.add_argument("--name", default="DORM-E")
    args = parser.parse_args()
    try:
        import dbus
        import dbus.mainloop.glib
        import dbus.service
        from gi.repository import GLib
    except ImportError as exc:
        atomic_write_json(args.status_file, {"state": "unavailable", "reason": f"Missing {exc.name}", "updated_at": time.time()})
        sys.exit(f"dorme-ble needs python3-dbus and python3-gi: {exc}")

    BLUEZ = "org.bluez"
    GATT_MGR, ADV_MGR = "org.bluez.GattManager1", "org.bluez.LEAdvertisingManager1"
    PROPS, OM = "org.freedesktop.DBus.Properties", "org.freedesktop.DBus.ObjectManager"
    GATT_SVC, GATT_CHR = "org.bluez.GattService1", "org.bluez.GattCharacteristic1"

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    om = dbus.Interface(bus.get_object(BLUEZ, "/"), OM)
    adapter = next((path for path, ifaces in om.GetManagedObjects().items() if GATT_MGR in ifaces), None)
    if not adapter:
        atomic_write_json(args.status_file, {"state": "unavailable", "reason": "No BLE adapter", "updated_at": time.time()})
        sys.exit("No Bluetooth adapter with GATT support")
    import glob
    for rf in glob.glob("/sys/class/rfkill/rfkill*"):     # this Pi booted with Bluetooth soft-blocked (2026-11-25)
        try:
            if open(rf + "/type").read().strip() == "bluetooth" and open(rf + "/soft").read().strip() == "1":
                with open(rf + "/soft", "w") as fh:
                    fh.write("0")
                time.sleep(1.0)
        except OSError:
            pass
    try:      # the adapter boots powered off on this Pi (2026-11-25); advertising needs it on
        dbus.Interface(bus.get_object(BLUEZ, adapter), PROPS).Set("org.bluez.Adapter1", "Powered", dbus.Boolean(True))
    except dbus.DBusException as exc:
        print(f"dorme-ble: could not power the adapter: {exc}", flush=True)

    class Characteristic(dbus.service.Object):
        def __init__(self, path, uuid, flags, service_path, reader=None, writer=None):
            self.path, self.uuid, self.flags = path, uuid, flags
            self.service_path, self.reader, self.writer = service_path, reader, writer
            self.notifying = False
            dbus.service.Object.__init__(self, bus, path)

        def props(self):
            return {GATT_CHR: {"Service": dbus.ObjectPath(self.service_path), "UUID": self.uuid,
                               "Flags": dbus.Array(self.flags, signature="s")}}

        @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return self.props()[GATT_CHR]

        @dbus.service.method(GATT_CHR, in_signature="a{sv}", out_signature="ay")
        def ReadValue(self, options):
            return dbus.Array(self.reader(), signature="y")

        @dbus.service.method(GATT_CHR, in_signature="aya{sv}")
        def WriteValue(self, value, options):
            if self.writer:
                self.writer(bytes(value))

        @dbus.service.method(GATT_CHR)
        def StartNotify(self):
            self.notifying = True

        @dbus.service.method(GATT_CHR)
        def StopNotify(self):
            self.notifying = False

        @dbus.service.signal(PROPS, signature="sa{sv}as")
        def PropertiesChanged(self, interface, changed, invalidated):
            pass

        def notify(self, data):
            if self.notifying:
                self.PropertiesChanged(GATT_CHR, {"Value": dbus.Array(data, signature="y")}, [])

    class Service(dbus.service.Object):
        def __init__(self, path, uuid, chars):
            self.path, self.uuid, self.chars = path, uuid, chars
            dbus.service.Object.__init__(self, bus, path)

        @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return {"UUID": self.uuid, "Primary": True}

    class App(dbus.service.Object):
        def __init__(self, services):
            self.services = services
            dbus.service.Object.__init__(self, bus, "/dorme")

        @dbus.service.method(OM, out_signature="a{oa{sa{sv}}}")
        def GetManagedObjects(self):
            out = {}
            for svc in self.services:
                out[dbus.ObjectPath(svc.path)] = {GATT_SVC: {"UUID": svc.uuid, "Primary": True}}
                for ch in svc.chars:
                    out[dbus.ObjectPath(ch.path)] = ch.props()
            return out

    class Advert(dbus.service.Object):
        def __init__(self):
            self.path = "/dorme/adv0"
            dbus.service.Object.__init__(self, bus, self.path)

        @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
        def GetAll(self, interface):
            return {"Type": "peripheral", "ServiceUUIDs": dbus.Array([api.BLE_SERVICE_UUID], signature="s"),
                    "LocalName": args.name, "Includes": dbus.Array(["tx-power"], signature="s")}

        @dbus.service.method("org.bluez.LEAdvertisement1")
        def Release(self):
            pass

    cache = {"status": b'{"v":1}', "state": None, "result": b'{"ok":null}'}
    assembler = ChunkAssembler()

    def on_command(data):
        word = data.strip().upper()
        try:
            if word == b"STOP":
                send_stop(args.api)
            elif word == b"CODE":
                post_json(args.api, "/api/v1/ble/code", {})
        except OSError:
            pass

    def set_result(obj):
        cache["result"] = json.dumps(obj, separators=(",", ":")).encode()[:api.BLE_MAX_PAYLOAD]
        result_chr.notify(cache["result"])

    def poll_result(tries=[0]):
        try:
            res = get_json(args.api, "/api/v1/ble/result")
        except (OSError, ValueError):
            res = {"ok": None}
        if res.get("ok") is None and tries[0] < 30:
            tries[0] += 1
            return True                      # keep polling every 2 s while the switch is running
        tries[0] = 0
        set_result({k: res.get(k) for k in ("ok", "ssid", "ipv4", "message") if res.get(k) is not None} or {"ok": None})
        return False

    def on_wifi(data):
        blob = assembler.feed(data)
        if blob is None:
            return
        import base64
        try:
            reply = post_json(args.api, "/api/v1/ble/wifi", {"blob": base64.b64encode(blob).decode()})
        except OSError:
            reply = {"ok": False, "message": "Robot service not answering"}
        if reply.get("ok"):
            set_result({"ok": None, "message": "Joining"})
            GLib.timeout_add_seconds(2, poll_result)
        else:
            set_result({"ok": False, "message": reply.get("message") or reply.get("code") or "Refused"})

    svc_path = "/dorme/service0"
    status_chr = Characteristic(svc_path + "/char0", api.BLE_STATUS_UUID, ["read", "notify"], svc_path,
                                reader=lambda: cache["status"])
    setup_chr = Characteristic(svc_path + "/char1", api.BLE_SETUP_UUID, ["read"], svc_path,
                               reader=lambda: setup_payload(int(args.api.rsplit(":", 1)[-1]), local_addresses()))
    cmd_chr = Characteristic(svc_path + "/char2", api.BLE_COMMAND_UUID, ["write"], svc_path, writer=on_command)
    wifi_chr = Characteristic(svc_path + "/char3", api.BLE_WIFI_UUID, ["write"], svc_path, writer=on_wifi)
    result_chr = Characteristic(svc_path + "/char4", api.BLE_RESULT_UUID, ["read", "notify"], svc_path,
                                reader=lambda: cache["result"])
    app = App([Service(svc_path, api.BLE_SERVICE_UUID, [status_chr, setup_chr, cmd_chr, wifi_chr, result_chr])])
    advert = Advert()

    reg = {"adv": None, "gatt": None}        # None = pending, True = accepted, str = BlueZ error

    def report(state, reason=None):
        if state == "advertising" and reg["adv"] is not True:
            state, reason = ("error", reg["adv"]) if isinstance(reg["adv"], str) else ("starting", reason)
        atomic_write_json(args.status_file, {"state": state, "reason": reason, "updated_at": time.time()})

    def registered(kind, ok):
        reg[kind] = True if ok is True else str(ok)[:80]

    def refresh():
        try:
            cache["status"] = status_payload(fetch_state(args.api))
            report("advertising")
        except (OSError, ValueError):
            cache["status"] = json.dumps({"v": 1, "err": "coordinator"}).encode()
            report("advertising", "Coordinator not answering")
        status_chr.notify(cache["status"])
        return True

    gatt = dbus.Interface(bus.get_object(BLUEZ, adapter), GATT_MGR)
    adv = dbus.Interface(bus.get_object(BLUEZ, adapter), ADV_MGR)
    gatt.RegisterApplication("/dorme", {}, reply_handler=lambda: registered("gatt", True),
                             error_handler=lambda e: registered("gatt", e))
    adv.RegisterAdvertisement(advert.path, {}, reply_handler=lambda: registered("adv", True),
                              error_handler=lambda e: registered("adv", e))
    GLib.timeout_add_seconds(2, refresh)
    refresh()
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
