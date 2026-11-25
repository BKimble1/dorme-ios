"""Health of every part, from what the Pi and the ESP32 can actually sense (2026-11-25).

SystemVitals samples the Pi every SAMPLE_S in the background (no root needed):
  SoC temperature   /sys/class/thermal/thermal_zone0/temp
  throttling flags  `vcgencmd get_throttled` (needs the video group; None if it cannot run)
  memory / disk     /proc/meminfo, statvfs("/")
  Wi-Fi             /proc/net/wireless (signal dBm) + `nmcli` (SSID), addresses from `ip -j addr`
  services          `systemctl is-active`
  remote access     `tailscale status --json` if Tailscale is installed

parts() turns those plus the coordinator's ESP32 view into one entry per part id (ids match the app's 3D model,
robot_parts.json). Status is one of: ok, warn, fault, off (not connected / switched off), none (no sensor).
Nothing is invented: a part with no sensor says so.
"""
import asyncio
import json
import os
import shutil
import time

from . import api

SAMPLE_S = 5.0
SERVICES = ("dorme-linkd", "dorme-face", "dorme-ble", "dorme-admin", "avahi-daemon", "tailscaled")
RANK = {"fault": 4, "warn": 3, "off": 2, "ok": 1, "none": 0}

# Thresholds. Spec-based where the spec gives one; the rest are stated as ours.
SOC_WARN_C, SOC_FAULT_C = 70.0, 80.0          # Pi 4 firmware soft-throttles at 80 C (Raspberry Pi docs)
MEM_WARN_MB, MEM_FAULT_MB = 300, 150           # B11 gate: >= 300 MB available
DISK_WARN_MB, DISK_FAULT_MB = 1024, 300
WIFI_WARN_DBM = -75

THROTTLE_BITS = {0: "under-voltage now", 1: "ARM frequency capped now", 2: "throttled now",
                 3: "soft temperature limit now", 16: "under-voltage has occurred",
                 17: "frequency capping has occurred", 18: "throttling has occurred",
                 19: "soft temperature limit has occurred"}


async def _run(*cmd, timeout=3.0):
    if not shutil.which(cmd[0]):
        return None
    try:
        proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout)
        return out.decode(errors="replace") if proc.returncode == 0 else None
    except (OSError, asyncio.TimeoutError):
        return None


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except OSError:
        return None


class SystemVitals:
    """Background sampler. On non-Linux hosts (tests, simulator on Windows) most values stay None."""

    def __init__(self, simulated=False):
        self.simulated = simulated
        self.data = {"sampled_at": None}
        self._task = None

    def start(self):
        if self._task is None:
            self._task = asyncio.get_running_loop().create_task(self._loop())

    def stop(self):
        if self._task:
            self._task.cancel()

    async def _loop(self):
        while True:
            try:
                await self.sample()
            except Exception:       # a sampler problem must never stop the coordinator
                pass
            await asyncio.sleep(SAMPLE_S)

    async def sample(self):
        d = {"sampled_at": time.time()}
        raw = _read("/sys/class/thermal/thermal_zone0/temp")
        d["soc_temp_c"] = round(int(raw) / 1000, 1) if raw and raw.strip().isdigit() else None
        out = await _run("vcgencmd", "get_throttled")
        flags = None
        if out and "=" in out:
            try:
                flags = int(out.strip().split("=", 1)[1], 16)
            except ValueError:
                pass
        d["throttled"] = flags
        mem = _read("/proc/meminfo")
        if mem:
            info = {line.split(":")[0]: int(line.split()[1]) for line in mem.splitlines() if line.split()[1:2]}
            d["mem_available_mb"] = info.get("MemAvailable", 0) // 1024
            d["mem_total_mb"] = info.get("MemTotal", 0) // 1024
        try:
            st = os.statvfs("/")
            d["disk_free_mb"] = st.f_bavail * st.f_frsize // (1024 * 1024)
        except (OSError, AttributeError):
            d["disk_free_mb"] = None
        try:
            d["load_1m"] = round(os.getloadavg()[0], 2)
        except (OSError, AttributeError):
            d["load_1m"] = None
        up = _read("/proc/uptime")
        d["uptime_s"] = int(float(up.split()[0])) if up else None
        d["wifi"] = await self._wifi()
        d["services"] = await self._services()
        d["remote"] = await self._tailscale()
        self.data = d

    async def _wifi(self):
        w = {"interface": "wlan0", "ssid": None, "signal_dbm": None, "ipv4": [], "connected": False}
        wl = _read("/proc/net/wireless")
        if wl:
            for line in wl.splitlines():
                if line.strip().startswith("wlan0:"):
                    parts = line.split()
                    try:
                        w["signal_dbm"] = int(float(parts[3].rstrip(".")))
                    except (IndexError, ValueError):
                        pass
        out = await _run("nmcli", "-t", "-f", "ACTIVE,SSID", "dev", "wifi")
        if out:
            for line in out.splitlines():
                if line.startswith("yes:"):
                    w["ssid"] = line[4:].replace("\\:", ":")
                    w["connected"] = True
        out = await _run("ip", "-j", "-4", "addr")
        if out:
            try:
                for iface in json.loads(out):
                    for a in iface.get("addr_info", []):
                        if iface.get("ifname") == "wlan0":
                            w["ipv4"].append(a.get("local"))
                        elif iface.get("ifname") == "eth0":
                            w.setdefault("ethernet_ipv4", []).append(a.get("local"))
            except ValueError:
                pass
        return w

    async def _services(self):
        out = await _run("systemctl", "is-active", *SERVICES)
        if out is None and not shutil.which("systemctl"):
            return {}
        states = (out or "").split()
        if len(states) != len(SERVICES):          # is-active exits non-zero when any unit is inactive
            states = []
            for unit in SERVICES:
                o = await _run("systemctl", "is-active", unit)
                states.append((o or "inactive").strip() or "inactive")
        return dict(zip(SERVICES, states))

    async def _tailscale(self):
        out = await _run("tailscale", "status", "--json")
        if out is None:
            return {"installed": bool(shutil.which("tailscale")), "online": False}
        try:
            data = json.loads(out)
        except ValueError:
            return {"installed": True, "online": False}
        me = data.get("Self") or {}
        return {"installed": True, "online": data.get("BackendState") == "Running" and bool(me.get("Online", True)),
                "state": data.get("BackendState"), "name": (me.get("DNSName") or "").rstrip(".") or None,
                "ips": (me.get("TailscaleIPs") or [])[:2], "login_url": data.get("AuthURL") or None}


def _item(pid, status, text, **values):
    return {"id": pid, "status": status, "text": text, "values": {k: v for k, v in values.items() if v is not None}}


def throttle_text(flags):
    if flags is None:
        return None
    return [THROTTLE_BITS[b] for b in sorted(THROTTLE_BITS) if flags & (1 << b)]


def parts(coord, vitals):
    """One health entry per part id. coord: Coordinator; vitals: SystemVitals.data."""
    v = vitals or {}
    sim = coord.mode == "simulator"
    s = coord.stat
    fresh = coord.stat_fresh()
    fault = coord.esp_fault()
    esp_state = s.get("state") if fresh else None
    rail_on = bool(s.get("mot_en")) if fresh else None
    out = []

    # ---- Pi ----
    temp, flags = v.get("soc_temp_c"), v.get("throttled")
    mem, disk = v.get("mem_available_mb"), v.get("disk_free_mb")
    status, text = "ok", "Running"
    issues = throttle_text(flags) or []
    if temp is not None and temp >= SOC_FAULT_C:
        status, text = "fault", f"Overheating {temp:.0f}°C"
    elif flags is not None and flags & 0x1:
        status, text = "fault", "Under-voltage"
    elif mem is not None and mem < MEM_FAULT_MB:
        status, text = "fault", f"Memory low {mem} MB"
    elif temp is not None and temp >= SOC_WARN_C:
        status, text = "warn", f"Hot {temp:.0f}°C"
    elif flags is not None and flags & 0xE:
        status, text = "warn", "Throttling"
    elif mem is not None and mem < MEM_WARN_MB:
        status, text = "warn", f"Memory {mem} MB free"
    elif disk is not None and disk < DISK_WARN_MB:
        status, text = ("fault" if disk < DISK_FAULT_MB else "warn"), f"Disk {disk} MB free"
    elif temp is not None:
        text = f"{temp:.0f}°C"
    if sim:
        status, text = "ok", "Simulated"
    out.append(_item("PI4", status, text, soc_temp_c=temp, throttled=issues or None, mem_available_mb=mem,
                     disk_free_mb=disk, load_1m=v.get("load_1m"), uptime_s=v.get("uptime_s")))

    # ---- radios / remote (virtual parts of the Pi) ----
    w = v.get("wifi") or {}
    if w.get("connected"):
        dbm = w.get("signal_dbm")
        out.append(_item("WIFI", "warn" if dbm is not None and dbm < WIFI_WARN_DBM else "ok",
                         w.get("ssid") or "Connected", ssid=w.get("ssid"), signal_dbm=dbm, ipv4=w.get("ipv4") or None))
    else:
        out.append(_item("WIFI", "off" if not sim else "ok", "Not connected" if not sim else "Simulated"))
    svc = v.get("services") or {}
    ble = coord.ble.status()
    out.append(_item("BLUETOOTH", "ok" if ble.get("status") in ("advertising", "simulated") else "off",
                     {"advertising": "Advertising", "simulated": "Simulated"}.get(ble.get("status"), "Off"),
                     service=svc.get("dorme-ble")))
    r = v.get("remote") or {}
    out.append(_item("REMOTE", "ok" if r.get("online") else "off",
                     (r.get("name") or "Online") if r.get("online") else ("Sign-in needed" if r.get("installed") else "Not set up"),
                     tailnet_name=r.get("name"), tailnet_ips=r.get("ips") or None))

    # ---- ESP32 and what it senses ----
    esp = coord.esp
    info = api.fault_info(fault) or {}
    if not esp["linkd"]:
        st, tx = "fault", "Link service down"
    elif esp["up"]:
        if fault and fault != "SONAR_FAIL":
            st, tx = "fault", info.get("title", fault)
        else:
            st, tx = "ok", "Linked"
    elif esp["ever_up"]:
        st, tx = "fault", "Link lost"
    else:
        st, tx = "off", "Not connected"
    boot = esp.get("boot") or {}
    out.append(_item("ESP32_U7", st, tx, state=esp_state, fault=fault, firmware=boot.get("fw"),
                     hb_gap_max_ms=s.get("hb_gap_max_ms") if fresh else None, stat_age_ms=coord.stat_age_ms()))

    vbus = s.get("vbus_mv", -1) if fresh else -1
    if fault in ("INA_FAIL",):
        out.append(_item("INA219_U9", "fault", "No reading", fault=fault))
    elif vbus is not None and vbus >= 0:
        out.append(_item("INA219_U9", "ok", f"{vbus / 1000:.2f} V", bus_v=round(vbus / 1000, 2)))
    else:
        out.append(_item("INA219_U9", "off" if not fresh else "none", "No data"))

    bat = coord.battery_view()
    if fault == "LOW_BUS" or coord.off_reason == "LOWBAT":
        out.append(_item("BATTERY", "fault", "Battery low", voltage_v=bat.get("voltage_v"), fault=fault))
    elif bat.get("voltage_v") is not None:
        out.append(_item("BATTERY", "warn" if bat.get("low") else "ok", f"{bat['voltage_v']:.1f} V",
                         voltage_v=bat["voltage_v"], percent=None))
    else:
        out.append(_item("BATTERY", "none", "No reading"))

    # U15 switches the motor rail; STAT.vmot_mv is VBAT_MOT at its output (about pack voltage, upstream of
    # F2/F3 and the XL4005 bucks, spec:449). The bucks' 6.30 V outputs and the drivers are not measured.
    vmot = s.get("vmot_mv", -1) if fresh else -1
    if fault in ("RAIL_DEAD", "RAIL_LIVE"):
        out.append(_item("U15", "fault", (api.fault_info(fault) or {}).get("title", fault), fault=fault))
    elif rail_on and vmot and vmot > 0:
        out.append(_item("U15", "ok", f"Motor rail {vmot / 1000:.1f} V", motor_rail_v=round(vmot / 1000, 1)))
    else:
        out.append(_item("U15", "off" if fresh else "none", "Motor rail off" if fresh else "No data"))
    for pid in ("XL4005_U2", "XL4005_U3", "MD20A_U4", "MD20A_U5"):
        out.append(_item(pid, "none", "No sensor", pwm=[s.get("pwm_l"), s.get("pwm_r")] if fresh and pid.startswith("MD") else None))
    jam = fault == "JAM"            # sonar-inferred on straight-forward moves; the side is not known
    for pid in ("M1", "M2", "M3", "M4"):
        out.append(_item(pid, "warn" if jam else "none", "Possible jam" if jam else "No sensor",
                         note="No motor current, speed or temperature sensing in V1"))

    sonar = s.get("sonar_cm", -1) if fresh else -1
    if fault == "SONAR_FAIL":
        out.append(_item("SONAR", "warn", "No echo", fault=fault))
    elif sonar is not None and sonar >= 0:
        out.append(_item("SONAR", "ok", f"{sonar} cm", distance_cm=sonar))
    else:
        out.append(_item("SONAR", "off" if not fresh else "none", "No data"))

    face = coord.face.status()
    face_ok = face["status"] in ("ok", "simulated") and (sim or svc.get("dorme-face", "active") == "active")
    out.append(_item("LCD", "ok" if face_ok else "fault", "Face running" if face_ok else "Face stopped", reason=face.get("reason")))

    cam = coord.camera.status()
    out.append(_item("CAMERA", "ok" if cam.get("status") in ("available", "simulated") else "off",
                     {"available": "Live", "simulated": "Simulated"}.get(cam.get("status"), "Not connected"),
                     reason=cam.get("reason")))
    aud = coord.audio.status()
    aud_ok = aud.get("status") in ("available", "detected", "simulated")
    out.append(_item("AUDIO_U16", "ok" if aud_ok else "off", "Detected" if aud_ok else "Not connected",
                     reason=aud.get("reason"), card=aud.get("card")))
    out.append(_item("SPEAKER", "none", "No sensor"))

    inputs = s.get("inputs", 0) if fresh else None
    plug = bool(inputs & 0x2) if inputs is not None else None            # GPIO34: charge plug in
    loop_open = bool(inputs & 0x1) if inputs is not None else None       # GPIO32: S2 OFF or plug (spec:291-297)
    out.append(_item("J_CHG", "warn" if plug else ("ok" if fresh else "none"),
                     "Plugged in" if plug else ("Unplugged" if fresh else "No data")))
    if inputs is None:
        out.append(_item("S2_SWITCH", "none", "No data"))
    else:
        out.append(_item("S2_SWITCH", "warn" if loop_open and not plug else "ok",
                         "Off (shutting down)" if loop_open and not plug else "On"))
    t1 = fault == "T1_LIVE"
    out.append(_item("K2_RELAY", "fault" if t1 else "none", "Charge path live" if t1 else "No sensor", fault=fault if t1 else None))
    for pid in ("FAN", "U1", "U14", "DCB", "TH1", "FUSE_F0", "FUSE_F1", "FUSE_F2", "FUSE_F3", "FUSE_F4"):
        if pid == "U1" and flags is not None and flags & 0x1:    # Pi under-voltage points at its 5 V supply U1
            out.append(_item(pid, "fault", "Pi under-voltage"))
        else:
            out.append(_item(pid, "none", "No sensor"))
    return out


def overall(items, coord):
    """(status, headline, issues) for the home screen."""
    worst = max((RANK.get(i["status"], 0) for i in items), default=0)
    issues = sorted((i for i in items if i["status"] in ("fault", "warn")),
                    key=lambda i: -RANK[i["status"]])
    if coord.off_reason:
        return "warn", "Shutting down", issues
    if worst >= RANK["fault"]:
        return "fault", issues[0]["text"] if issues else "Fault", issues
    if worst >= RANK["warn"]:
        return "warn", issues[0]["text"] if issues else "Check", issues
    return "ok", "Operational", issues
