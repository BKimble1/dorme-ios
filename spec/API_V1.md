# DORM-E app API v1 (shared communication specification)

Date: 2026-11-25. Status: implemented in `pi/dorme_coord` (tested against the simulator) and mirrored in
`ios/DORMEKit` (written, **not yet compiled**). Machine-readable schema: `schema/api_v1.schema.json`.
Fixtures recorded from real coordinator runs: `fixtures/`.

This API sits **above** the Pi ↔ ESP32 serial protocol in `output/electrical/SOFTWARE_AND_FIRMWARE_SPEC.md`
section 2, which is unchanged. GPIO assignments, firmware limits, voltages and protection are not touched.

## 1. Transports and roles

| Path | Carries | Notes |
|---|---|---|
| Wi-Fi HTTP `:8080/api/v1/…` | info, pairing, stop, tasks, camera | Plain HTTP on the local network (spec section 8 deviation) |
| Wi-Fi WebSocket `/api/v1/ws` | state (≈1 Hz and on change), events, commands, acks | One socket per phone |
| BLE GATT (Pi radio) | discovery, setup info, compact status, STOP | Never driving. Bridge untested on hardware |
| USB serial (linkd only) | frames to the ESP32 | Unchanged spec section 2 |

Every command source — the app, BLE, tasks, local tools (and later voice) — calls the same
`Coordinator.submit()`. Only `dorme-linkd` opens the serial port.

## 2. Pairing and access

- `GET /api/v1/info` (no auth): `{name, api, software, mode, simulated, paired, pin_source}`.
- `POST /api/v1/pair {"pin": "123456", "client_name": "iPhone"}` → ack with `result.token`.
  5 wrong PINs lock pairing for 60 s, doubling. PIN source: the existing dorme-web label store if readable,
  else the coordinator's own `pin.txt` (root-only, never printed on hardware).
- `POST /api/v1/pair/show` (no auth, body ignored): the robot draws a fresh **one-time 6-digit code** in large
  digits on its own face screen for 120 s (asking again while one is live keeps the same code and its expiry).
  The reply never contains the code: `{"ok": true, "result": {"expires_in_s": 118, "shown_on": "robot_screen"}}`.
  `POST /api/v1/pair` accepts that code once, in place of the PIN; it counts towards the same lockout.
  `503 UNAVAILABLE` if the robot has no working screen; `423 LOCKED_OUT` during a lockout.
- Then send `Authorization: Bearer <token>` on HTTP and on the WebSocket upgrade.
- **Stop needs no pairing**: `POST /api/v1/stop`. Anyone on the network can stop; nobody unpaired can start.
- Loopback callers are trusted when `trust_loopback` is true (hardware default, for the BLE bridge).
- A WebSocket with a foreign `Origin` header is refused (browsers); the native app sends none.

## 3. Message envelopes

Command (client → robot, WebSocket text frame or `POST /api/v1/commands`):
```json
{"v":1,"type":"command","id":"ios-1a2b3c4d","name":"drive.hold","args":{"claim":"3-9f2c1a7e","direction":"F","seq":17}}
```
Ack (one per command): `{"v":1,"type":"ack","id":…,"ok":true|false,"code":null|CODE,"message":"…","result":{…}}`
Robot → client also sends `{"type":"hello","client","state","capabilities"}` on connect,
`{"type":"state","state":{…}}` and `{"type":"event","event":{"kind":…,…}}`.

## 4. Commands

| name | args | auth | effect |
|---|---|---|---|
| `stop` | – | **none** | STOP to the link (even in bench mode), drops the movement owner, bumps the claim epoch, cancels any task |
| `drive.claim` | – | yes | Become the movement owner. Returns `claim`, `lease_ms`, `hold_interval_ms`, `outputs` |
| `drive.hold` | `claim`, `direction` F/B/L/R, `seq` (int, increasing) | yes | Keep driving for `lease_ms` (500). Bench mode: accepted, `delivered:false` |
| `drive.release` | `claim` | yes | Stop driving now |
| `task.start` | `action` | yes | Start one task (one at a time) |
| `task.cancel` | `task_id` (optional) | yes | Cancel the running task; stops motion |
| `fault.rearm` | `confirm: true` | yes | REARM to the ESP32, only for rearmable faults, never starts motion |
| `state.get` / `capabilities.get` | – | yes | Snapshot in `result` |

### Movement ownership (the rules the tests check)

1. One owner at a time: `app:<session>`, `task:<id>`, later `voice`. Others get `BUSY`.
2. A lease lives `hold_lease_ms` (500) after the last accepted hold. **Nothing else extends it** — no
   heartbeat, ping or state request. On expiry the coordinator sends STOP. The ESP32's own 300 ms DRV
   expiry is the backstop, and a DRV is never extended by a heartbeat (firmware `dorme_controller.cpp:502`).
3. Holds must quote the current claim and a strictly larger `seq`, else `STALE`.
4. Every stop bumps the epoch: claims made before it are dead (`STALE`). The user must press again.
5. WebSocket close, link loss, ESP32 reset (BOOT), linkd restart, shutdown, fault → owner dropped.
   Nothing is persisted, so **a restart or reconnect never resumes movement**.
6. Motion tasks own movement for their whole run; the app cannot drive meanwhile (`TASK_ACTIVE`).

## 5. Ack codes

`UNAUTHORIZED, BAD_REQUEST, UNKNOWN_COMMAND, RATE_LIMITED, LOCKED_OUT, BAD_PIN, NO_CODE, BUSY, NOT_OWNER, STALE,
LINK_DOWN, NOT_READY, FAULT, PLUG, SHUTTING_DOWN, NETWORK_SHARED, TASK_ACTIVE, NO_TASK, UNAVAILABLE,
CONFIRM_REQUIRED, NO_FAULT, REARM_REFUSED, MOVE_REFUSED, INTERNAL`. Texts: `pi/dorme_coord/api.py`.
The app adds `TIMEOUT` and `OFFLINE` locally. Driving is refused, in order, for: shutting down, shared
network, then (outside bench mode) link down, latched fault, charge plug, ESP32 not READY.

## 6. Robot state document

Top-level keys (all required): `seq, robot, connection, battery, motion, task, fault, power, face,
peripherals, network, not_measured`. See `fixtures/state_*.json`.

- `robot.mode`: `hardware` or `simulator` (the app's own Demo uses `demo`). `robot.simulated` and
  `battery.simulated` are true whenever values are synthetic. The app labels them on every screen.
- `battery.voltage_v`: INA219 bus voltage at the logic rail, or `null` with `voltage_reason`.
  `percent` is **always null** until a discharge log (B22) exists. `low` is `null` while no calibrated
  threshold exists. `under_load` holds the band while motors ran in the last 5 s.
- `motion.state` is **commanded**, never measured (no encoders): `basis: "commanded"`.
  `outputs: "disabled_bench"` in bench mode. `drive_block` gives the refusal code before you try.
- `connection.esp32`: `up | lost | never | linkd_down`. `lost` raises the pseudo-fault `LINK_LOST`
  ("Stop cannot reach the wheels: use S2").
- `fault.active`: `{code,title,detail,rearm}`; rearm ∈ `phone_or_voice | phone | service | auto`.
- `peripherals.camera|audio|ble|sonar`: `{status, reason}`. Status ∈ `available, detected,
  advertising, simulated, unavailable, not_running, no_permission, error`.
- `not_measured`: `current, runtime, temperature, motor_rpm, charging_status, wheel_speed` — the app
  states these cannot be measured; they never appear as values.

### Staleness (app side, from spec section 8)

Ages are measured on the phone from receipt. Older than 3 s → **stale** (values greyed, age shown).
No message for 10 s or socket closed → **offline, last seen HH:MM:SS**. Driving is disabled unless live.

## 7. Tasks

States: `pending → running → succeeded | failed | cancelled`. One task at a time. Catalog
(`capabilities.tasks`) lists each action with `available` and, if not, `unavailable_code/_reason`.

| action | moves | notes |
|---|---|---|
| `greet` | no | Happy face 2.5 s. Chime skipped: audio playback not connected yet |
| `self_check` | no | Reports each subsystem as ok / warn / unavailable, measured only |
| `move_forward_short`, `turn_left_short`, `turn_right_short` | yes | One bounded MOVE; firmware clips/refuses. Bench: timed rehearsal, nothing sent |
| `take_photo` | no | Needs a camera; simulator returns a labelled test card |
| `go_to_desk` | yes | Always unavailable: marker navigation is not built |

History (last 20) persists; a task running when the coordinator stopped is recorded `failed … not resumed`.

## 8. Events

`task.updated{task}`, `stop{source,reached_controller,…}`, `drive.owner{owner|null,reason?}`,
`drive.ended`, `motion.stopped`, `link.changed{linkd,esp32}`, `fault.raised{fault}`, `fault.cleared`,
`controller.boot{reset_reason,fw}`, `power.shutting_down{reason}`.

## 9. Camera

`GET /api/v1/camera/stream.mjpg` (multipart JPEG, auth), `snapshot.jpg`, `last.jpg` (last task photo).
503 with a reason when unavailable. Frames are sent unrotated; `rotation_deg` is `null` until the bench
frame test (spec 7b) and `rotation_verified` stays false.

## 10. BLE GATT

Service `6f1e0001-4c2b-4b7e-9d8a-d0a7e0b10001`:
`…0002` status (read/notify, compact JSON ≤ 180 B: `v,n,sim,bv,esp,mo,bench,f,t,tp,s`),
`…0003` setup (read: `{v,port,addrs,bonjour}`), `…0004` command (write: ASCII `STOP` only).
