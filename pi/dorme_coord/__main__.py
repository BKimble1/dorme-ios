"""Run the DORM-E coordinator.

  Simulator (any computer, no hardware):
      python -m dorme_coord --backend sim [--no-bench] [--port 8080]
  Hardware (on the Pi, next to the real dorme-linkd):
      python3 -m dorme_coord --backend linkd --config /etc/dorme/coordinator.json

Bench mode is on by default. --no-bench is accepted only with the simulator; on hardware, bench
mode can only be turned off in the config file (and dorme-linkd's own dry_run must also be off).
"""
import argparse
import asyncio
import logging
import os
import sys
import tempfile
from pathlib import Path

from . import config as config_mod
from .auth import Auth
from .coordinator import Coordinator
from .face_adapter import FaceAdapter
from .http_server import ApiServer
from .link import FrameBackend, LinkdBackend, SimTransport
from .peripherals import AudioService, BleStatus, CameraService, RpiCamera, SimCamera


def build(args, announce=print):
    simulator = args.backend == "sim"
    config = config_mod.load(args.config, simulator=simulator)
    if args.port is not None:
        config["port"] = args.port
    if args.host:
        config["host"] = args.host
    if simulator:
        config["state_dir"] = args.state_dir or str(Path(tempfile.gettempdir()) / "dorme-sim")
        if args.no_bench:
            config["bench_mode"] = False
        from .esp_sim import Esp32Sim
        sim = Esp32Sim()
        link = FrameBackend(SimTransport(sim), config)
        face = FaceAdapter(Path(config["state_dir"]) / "face", create_dir=True)
        camera = SimCamera()
        audio = AudioService(simulated=True)
        ble = BleStatus(simulated=True)
        mode = "simulator"
    else:
        if args.no_bench:
            sys.exit("--no-bench is refused on hardware. Set bench_mode false in the config file deliberately.")
        if args.state_dir:
            config["state_dir"] = args.state_dir
        sim = None
        link = LinkdBackend(config["linkd_socket"])
        face = FaceAdapter(config["face_state_dir"])
        cam = RpiCamera(config["camera_width"], config["camera_height"], config["camera_fps"])
        camera = cam if cam.status()["status"] == "available" else CameraService(cam.status()["reason"])
        audio = AudioService(config["audio_card_match"])
        ble = BleStatus(config["ble_status_file"])
        mode = "hardware"
    Path(config["state_dir"]).mkdir(parents=True, exist_ok=True)
    from .admin import AdminClient, SimAdmin
    admin = SimAdmin() if simulator else AdminClient(config.get("admin_socket", "/run/dorme-admin/admin.sock"))
    coord = Coordinator(config, link, mode=mode, face=face, camera=camera, audio=audio, ble=ble, admin=admin)
    auth = Auth(config["state_dir"], pin_file=config.get("pin_file"), simulator=simulator, announce=announce)
    server = ApiServer(coord, auth, config["host"], config["port"], trust_loopback=config["trust_loopback"])
    return coord, server, sim, config


async def run(args):
    coord, server, sim, config = build(args)
    await coord.start()
    port = await server.start()
    banner = "SIMULATOR (no hardware)" if sim else "HARDWARE via dorme-linkd"
    print(f"DORM-E coordinator: {banner}; bench_mode={config['bench_mode']}; "
          f"network_trust={config['network_trust']}; API http://{config['host']}:{port}/api/v1/", flush=True)
    if sim and args.sim_console:
        asyncio.get_running_loop().create_task(sim_console(sim))
    try:
        await asyncio.Event().wait()
    finally:
        await server.close()
        await coord.close()


async def sim_console(sim):
    """Type simulator controls on stdin: vbus 8700 | sonar 15 | fault JAM | s2off | reset | unplug | replug"""
    loop = asyncio.get_running_loop()
    print("Simulator controls: vbus <mV> | sonar <cm> | fault <CODE> | s2off | plug | reset | unplug | replug | silence <s>")
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            return
        parts = line.split()
        if parts:
            try:
                sim.control(parts[0], parts[1] if len(parts) > 1 else None)
                print("ok")
            except (ValueError, TypeError) as exc:
                print(f"error: {exc}")


def main():
    parser = argparse.ArgumentParser(description="DORM-E coordinator")
    parser.add_argument("--backend", choices=("sim", "linkd"), required=True)
    parser.add_argument("--config")
    parser.add_argument("--host")
    parser.add_argument("--port", type=int)
    parser.add_argument("--state-dir")
    parser.add_argument("--no-bench", action="store_true", help="simulator only: let simulated motors run")
    parser.add_argument("--sim-console", action="store_true", help="read simulator controls from stdin")
    args = parser.parse_args()
    logging.basicConfig(level=os.environ.get("DORME_LOG", "INFO"), format="%(name)s: %(levelname)s %(message)s")
    try:
        asyncio.run(run(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
