"""dorme-admin: the one small root helper (2026-11-25). The coordinator stays unprivileged and sandboxed.

Listens on /run/dorme-admin/admin.sock (root:dorme 0660). One JSON request per line, one JSON reply per line.
Only these operations exist; anything else is refused:

  wifi.status                       active connection, SSID, addresses
  wifi.scan                         visible networks (ssid, signal %, security)
  wifi.saved                        saved Wi-Fi profiles (names only, never secrets)
  wifi.add    {ssid, psk | eap:{identity,password,domain?}, hidden?, priority?, connect?}
              writes a root-only NetworkManager keyfile (secrets never appear on a command line), reloads,
              and with connect=true switches in the background, ROLLING BACK to the previous network if the
              new one does not come up within 30 s. The outcome is kept for wifi.result.
  wifi.result                       outcome of the last switch
  wifi.forget {ssid}                refuses the network in use unless force=true
  service.restart {unit}            only dorme-linkd, dorme-coordinator, dorme-face, dorme-ble
  system.reboot / system.poweroff   normal systemd paths (shutdown hook included)
  remote.up                         `tailscale up` (plain OpenSSH over the tailnet; no Tailscale SSH, whose
                                    default check mode would stall unattended sessions); returns the sign-in URL
  bluetooth.on                      unblock + power the adapter

Run (root): python3 -m dorme_coord.admin [--socket /run/dorme-admin/admin.sock]
"""
import argparse
import asyncio

import json
import logging
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path

log = logging.getLogger("dorme-admin")
SOCKET = "/run/dorme-admin/admin.sock"
KEYFILE_DIR = Path("/etc/NetworkManager/system-connections")
RESULT_FILE = Path("/run/dorme-admin/wifi_result.json")
SERVICES = {"dorme-linkd", "dorme-coordinator", "dorme-face", "dorme-ble"}
CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"
SWITCH_TIMEOUT_S = 30


class AdminError(Exception):
    pass


def run(*cmd, timeout=20, check=False):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        if check:
            raise AdminError(f"{cmd[0]} failed: {exc.__class__.__name__}")
        return 1, ""
    if check and p.returncode != 0:
        raise AdminError((p.stderr or p.stdout or f"{cmd[0]} failed").strip()[:200])
    return p.returncode, p.stdout


def nm_fields(line):
    """Split one `nmcli -t` line on unescaped colons."""
    return [f.replace("\\:", ":").replace("\\\\", "\\") for f in re.split(r"(?<!\\):", line)]


# ------------------------------------------------------------------ validation
def check_ssid(ssid):
    if not isinstance(ssid, str) or not 1 <= len(ssid.encode()) <= 32 or any(ord(c) < 32 for c in ssid):
        raise AdminError("Network name must be 1-32 bytes with no control characters.")
    return ssid


def check_secret(value, what, lo=1, hi=128):
    if not isinstance(value, str) or not lo <= len(value) <= hi or any(ord(c) < 32 for c in value):
        raise AdminError(f"{what} is not valid.")
    return value


def keyfile_escape(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace(";", "\\;")


def build_keyfile(conn_id, ssid, psk=None, eap=None, hidden=False, priority=0):
    lines = ["[connection]", f"id={keyfile_escape(conn_id)}", f"uuid={uuid.uuid4()}", "type=wifi",
             "autoconnect=true", f"autoconnect-priority={int(priority)}", "",
             "[wifi]", "mode=infrastructure", f"ssid={keyfile_escape(ssid)}", "powersave=2"]
    if hidden:
        lines.append("hidden=true")
    lines.append("")
    if eap:
        identity = check_secret(eap.get("identity"), "Username")
        password = check_secret(eap.get("password"), "Password")
        lines += ["[wifi-security]", "key-mgmt=wpa-eap", "", "[802-1x]", "eap=peap;", f"identity={keyfile_escape(identity)}",
                  f"password={keyfile_escape(password)}", "phase2-auth=mschapv2"]
        domain = eap.get("domain")
        if domain:
            if not re.fullmatch(r"[A-Za-z0-9.-]{3,253}", domain):
                raise AdminError("Server domain is not valid.")
            lines += [f"ca-cert={CA_BUNDLE}", f"domain-suffix-match={domain}"]
        lines.append("")
    elif psk is not None:
        check_secret(psk, "Wi-Fi password", 8, 64)
        lines += ["[wifi-security]", "key-mgmt=wpa-psk", f"psk={keyfile_escape(psk)}", ""]
    lines += ["[ipv4]", "method=auto", "", "[ipv6]", "addr-gen-mode=default", "method=auto", ""]
    return "\n".join(lines)


# ------------------------------------------------------------------ operations
def wifi_status():
    _, out = run("nmcli", "-t", "-f", "NAME,TYPE,DEVICE", "connection", "show", "--active")
    active = [nm_fields(l) for l in out.splitlines() if l]
    wifi = next((a[0] for a in active if len(a) > 2 and a[1] == "802-11-wireless" and a[2] == "wlan0"), None)
    _, out = run("nmcli", "-t", "-f", "ACTIVE,SSID,SIGNAL", "dev", "wifi")
    cur = next((nm_fields(l) for l in out.splitlines() if l.startswith("yes:")), None)
    _, addr = run("ip", "-4", "-o", "addr", "show", "wlan0")
    ips = re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", addr)
    return {"connection": wifi, "ssid": cur[1] if cur else None, "signal": int(cur[2]) if cur and cur[2].isdigit() else None,
            "ipv4": ips}


def wifi_scan():
    _, out = run("nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "dev", "wifi", "list", "--rescan", "auto", timeout=25)
    best = {}
    for line in out.splitlines():
        f = nm_fields(line)
        if len(f) < 3 or not f[0]:
            continue
        sig = int(f[1]) if f[1].isdigit() else 0
        if f[0] not in best or sig > best[f[0]]["signal"]:
            best[f[0]] = {"ssid": f[0], "signal": sig, "security": "enterprise" if "802.1X" in f[2] else
                          ("open" if f[2] in ("", "--") else "password")}
    return {"networks": sorted(best.values(), key=lambda n: -n["signal"])[:25]}


def wifi_saved():
    _, out = run("nmcli", "-t", "-f", "NAME,TYPE,AUTOCONNECT-PRIORITY", "connection", "show")
    saved = []
    for line in out.splitlines():
        f = nm_fields(line)
        if len(f) >= 3 and f[1] == "802-11-wireless":
            _, ssid = run("nmcli", "-g", "802-11-wireless.ssid", "connection", "show", f[0])
            saved.append({"name": f[0], "ssid": ssid.strip() or f[0], "priority": int(f[2]) if f[2].lstrip("-").isdigit() else 0})
    return {"saved": saved}


def _profiles_for(ssid):
    return [s["name"] for s in wifi_saved()["saved"] if s["ssid"] == ssid]


def write_result(data):
    RESULT_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = RESULT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(dict(data, at=time.time())))
    os.replace(tmp, RESULT_FILE)


async def switch_to(conn_id, previous):
    await asyncio.sleep(1.5)            # let the reply reach the phone before the network changes
    rc, _ = await asyncio.to_thread(run, "nmcli", "--wait", str(SWITCH_TIMEOUT_S), "connection", "up", "id", conn_id,
                                    timeout=SWITCH_TIMEOUT_S + 10)
    if rc == 0:
        write_result({"ok": True, "ssid": conn_id, "ipv4": wifi_status()["ipv4"]})
        log.info("Switched Wi-Fi to %s", conn_id)
        return
    log.warning("Could not join %s; rolling back to %s", conn_id, previous)
    if previous:
        await asyncio.to_thread(run, "nmcli", "--wait", "30", "connection", "up", "id", previous, timeout=40)
    write_result({"ok": False, "ssid": conn_id, "message": "Could not join. Check the password and range.",
                  "rolled_back_to": previous})


async def wifi_add(req):
    ssid = check_ssid(req.get("ssid"))
    eap, psk = req.get("eap"), req.get("psk")
    if eap is not None and not isinstance(eap, dict):
        raise AdminError("eap must be an object.")
    priority = max(-100, min(100, int(req.get("priority", 10))))
    conn_id = ssid
    if wifi_status()["ssid"] == ssid and not req.get("force"):
        raise AdminError("The robot is already on this network.")
    for name in _profiles_for(ssid):        # replace an older profile for the same network
        run("nmcli", "connection", "delete", "id", name)
    path = KEYFILE_DIR / f"dorme-{uuid.uuid4().hex[:8]}.nmconnection"
    data = build_keyfile(conn_id, ssid, psk=psk, eap=eap, hidden=bool(req.get("hidden")), priority=priority)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(data)
    run("nmcli", "connection", "load", str(path), check=True)
    unverified = bool(eap) and not eap.get("domain")
    if req.get("connect"):
        previous = wifi_status()["connection"]
        write_result({"ok": None, "ssid": ssid, "message": "Switching"})
        asyncio.get_running_loop().create_task(switch_to(conn_id, previous))
        return {"saved": True, "switching": True, "previous": previous, "server_unverified": unverified}
    return {"saved": True, "switching": False, "server_unverified": unverified}


def wifi_forget(req):
    ssid = check_ssid(req.get("ssid"))
    names = _profiles_for(ssid)
    if not names:
        raise AdminError("No saved network with that name.")
    if wifi_status()["connection"] in names and not req.get("force"):
        raise AdminError("That network is in use. Join another first, or confirm.")
    for name in names:
        run("nmcli", "connection", "delete", "id", name, check=True)
    return {"forgotten": names}


async def later(*cmd, delay=1.5):
    await asyncio.sleep(delay)
    await asyncio.to_thread(run, *cmd, timeout=30)


async def handle(req):
    op = req.get("op")
    if op == "wifi.status":
        return wifi_status()
    if op == "wifi.scan":
        return await asyncio.to_thread(wifi_scan)
    if op == "wifi.saved":
        return wifi_saved()
    if op == "wifi.add":
        return await wifi_add(req)
    if op == "wifi.result":
        try:
            return json.loads(RESULT_FILE.read_text())
        except (OSError, ValueError):
            return {"ok": None, "message": "No switch yet"}
    if op == "wifi.forget":
        return wifi_forget(req)
    if op == "service.restart":
        unit = req.get("unit")
        if unit not in SERVICES:
            raise AdminError("That service cannot be restarted from the app.")
        asyncio.get_running_loop().create_task(later("systemctl", "restart", unit))
        return {"restarting": unit}
    if op in ("system.reboot", "system.poweroff"):
        asyncio.get_running_loop().create_task(later("systemctl", op.split(".")[1], delay=2))
        return {"accepted": op}
    if op == "remote.up":
        if not shutil.which("tailscale"):
            raise AdminError("Tailscale is not installed on the robot.")
        await asyncio.to_thread(run, "tailscale", "up", "--hostname=dorm-e", "--accept-dns=false",
                                "--timeout=8s", timeout=20)
        _, out = run("tailscale", "status", "--json")
        try:
            data = json.loads(out)
        except ValueError:
            data = {}
        return {"state": data.get("BackendState"), "login_url": data.get("AuthURL") or None,
                "name": ((data.get("Self") or {}).get("DNSName") or "").rstrip(".") or None}
    if op == "bluetooth.on":
        run("rfkill", "unblock", "bluetooth")
        run("bluetoothctl", "power", "on")
        return {"powered": True}
    raise AdminError("Unknown operation.")


async def serve(path):
    sock_path = Path(path)
    sock_path.parent.mkdir(parents=True, exist_ok=True)
    if sock_path.exists():
        sock_path.unlink()

    async def client(reader, writer):
        try:
            line = await asyncio.wait_for(reader.readline(), 10)
            req = json.loads(line or b"{}")
            if not isinstance(req, dict):
                raise AdminError("Bad request.")
            log.info("op %s", req.get("op"))        # never log the request body (it may hold passwords)
            reply = {"ok": True, "result": await handle(req)}
        except AdminError as exc:
            reply = {"ok": False, "error": str(exc)}
        except (ValueError, asyncio.TimeoutError):
            reply = {"ok": False, "error": "Bad request."}
        except Exception:
            log.exception("admin op failed")
            reply = {"ok": False, "error": "Internal error."}
        try:
            writer.write((json.dumps(reply) + "\n").encode())
            await writer.drain()
        finally:
            writer.close()

    server = await asyncio.start_unix_server(client, path)
    try:
        import grp                       # POSIX only; this server runs on the Pi
        os.chown(path, 0, grp.getgrnam("dorme").gr_gid)
    except (ImportError, KeyError, PermissionError):
        pass
    os.chmod(path, 0o660)
    log.info("dorme-admin on %s", path)
    async with server:
        await server.serve_forever()


class AdminClient:
    """Used by the coordinator (user dorme). Each call is one short connection."""

    def __init__(self, path=SOCKET):
        self.path = path

    def available(self):
        return os.path.exists(self.path)

    async def call(self, op, timeout=30, **args):
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(self.path), 3)
        except (OSError, asyncio.TimeoutError, AttributeError):
            return {"ok": False, "error": "The robot's admin helper (dorme-admin) is not running."}
        try:
            writer.write((json.dumps(dict(args, op=op)) + "\n").encode())
            await writer.drain()
            line = await asyncio.wait_for(reader.readline(), timeout)
            return json.loads(line) if line else {"ok": False, "error": "No reply."}
        except (OSError, ValueError, asyncio.TimeoutError):
            return {"ok": False, "error": "The admin helper did not answer."}
        finally:
            writer.close()


class SimAdmin:
    """Simulator stand-in: plausible answers, changes nothing on the computer it runs on."""

    def __init__(self):
        self.saved = [{"name": "Home", "ssid": "Home", "priority": 0}]
        self.current = "Home"

    def available(self):
        return True

    async def call(self, op, timeout=30, **args):
        if op == "wifi.status":
            return {"ok": True, "result": {"connection": self.current, "ssid": self.current, "signal": 78,
                                            "ipv4": ["127.0.0.1"]}}
        if op == "wifi.saved":
            return {"ok": True, "result": {"saved": list(self.saved)}}
        if op == "wifi.scan":
            return {"ok": True, "result": {"networks": [{"ssid": "Home", "signal": 78, "security": "password"},
                                                        {"ssid": "Campus Secure", "signal": 55, "security": "enterprise"},
                                                        {"ssid": "Guest", "signal": 40, "security": "open"}]}}
        if op == "wifi.add":
            try:
                check_ssid(args.get("ssid"))
            except AdminError as exc:
                return {"ok": False, "error": str(exc)}
            self.saved = [s for s in self.saved if s["ssid"] != args["ssid"]] + [
                {"name": args["ssid"], "ssid": args["ssid"], "priority": 10}]
            return {"ok": True, "result": {"saved": True, "switching": bool(args.get("connect")), "simulated": True}}
        if op == "wifi.result":
            return {"ok": True, "result": {"ok": True, "ssid": self.current, "simulated": True}}
        if op == "wifi.forget":
            self.saved = [s for s in self.saved if s["ssid"] != args.get("ssid")]
            return {"ok": True, "result": {"forgotten": [args.get("ssid")]}}
        if op in ("service.restart", "system.reboot", "system.poweroff"):
            return {"ok": True, "result": {"accepted": op, "simulated": True}}
        if op == "remote.up":
            return {"ok": True, "result": {"state": "NeedsLogin", "login_url": None, "simulated": True}}
        return {"ok": False, "error": "Unknown operation."}


def main():  # pragma: no cover - needs root and NetworkManager
    parser = argparse.ArgumentParser(description="DORM-E root helper")
    parser.add_argument("--socket", default=SOCKET)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="dorme-admin: %(levelname)s %(message)s")
    asyncio.run(serve(args.socket))


if __name__ == "__main__":
    main()
