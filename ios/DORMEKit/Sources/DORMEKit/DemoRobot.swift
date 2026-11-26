import Foundation

/// Isolated Demo mode. A self-contained simulation that never opens a socket, so it can never
/// reach a real robot. Every state it emits says mode "demo" and simulated true, and the app labels
/// it on every screen. It follows the same command rules as the Pi coordinator (one owner, leases,
/// stop overrides tasks, nothing resumes after a disconnect) so the UI is exercised honestly.
@MainActor
public final class DemoRobot: RobotClient {
    public let isDemo = true
    public let displayName = "DORM-E (Demo)"
    public var onEvent: ((ClientEvent) -> Void)?

    // Scenario switches, driven from the Demo controls sheet.
    public private(set) var lowBattery = false
    public private(set) var cameraAvailable = true
    public private(set) var benchMode = false
    public private(set) var controllerLinked = true
    public private(set) var networkDown = false

    private var connected = false
    private var ticker: Task<Void, Never>?
    private var seq = 0
    private var voltage = 9.64
    private var fault: FaultInfo?
    private var note: ScreenNote?
    private var noteExpires: Date?
    private var owner: (client: String, claim: String, seq: Int, direction: Direction?, leaseUntil: Date?)?
    private var epoch = 0
    private var task: RobotTask?
    private var taskRunner: Task<Void, Never>?
    private var history: [RobotTask] = []
    private var lastStop: LastStop?
    private var transientFace: (name: String, until: Date)?
    private var stoppedAt = Date.distantPast
    private let clientID = "demo-phone"
    private let leaseMs = 500
    private var clock: () -> Date

    public init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    // MARK: RobotClient

    public func connect() async {
        guard !connected else { return }
        onEvent?(.phase(.connecting))
        try? await Task.sleep(nanoseconds: 700_000_000)
        connected = true
        networkDown = false
        onEvent?(.phase(.connected))
        onEvent?(.capabilities(capabilities()))
        emitState()
        emitTasks()
        ticker?.cancel()
        ticker = Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                n += 1
                self.tick(emit: n % 5 == 0)
            }
        }
    }

    public func disconnect() async {
        ticker?.cancel()
        ticker = nil
        connected = false
        dropMotion(reason: "Disconnected")
        onEvent?(.phase(.idle))
    }

    public func pair(pin: String) async -> Ack { Ack(id: nil, ok: true, result: ["token": .string("demo")]) }

    public func stop() async -> Ack { await send(.stop()) }

    public func refreshTasks() async { emitTasks() }

    public func send(_ command: RobotCommand) async -> Ack {
        // A stop always "reaches" the demo; everything else needs the demo network to be up.
        if networkDown && command.name != "stop" {
            return .failure(command.id, "OFFLINE")
        }
        let ack = handle(command)
        emitState()
        return ack
    }

    // MARK: Scenario controls

    public func setLowBattery(_ on: Bool) { lowBattery = on; voltage = on ? 8.94 : 9.64; emitState() }
    public func setCameraAvailable(_ on: Bool) { cameraAvailable = on; emitState(); onEvent?(.capabilities(capabilities())) }
    public func setBenchMode(_ on: Bool) { benchMode = on; dropMotion(reason: "Mode changed"); emitState() }

    public func setControllerLinked(_ on: Bool) {
        controllerLinked = on
        if !on { dropMotion(reason: "Controller link lost") }
        emitState()
    }

    public func injectFault(_ code: String = "STALE") {
        fault = DemoRobot.fault(code)
        dropMotion(reason: "Fault \(code)")
        emitEvent("fault.raised", ["code": .string(code)])
        emitState()
    }

    /// Simulates the phone losing Wi-Fi for `seconds`: no messages arrive, so the app shows stale
    /// data after 3 s and offline after 10 s. The robot side stops motion (lease) and, when the
    /// connection returns, nothing resumes.
    public func simulateDisconnect(seconds: Double = 14) {
        networkDown = true
        dropMotion(reason: "Phone disconnected")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.networkDown else { return }
            self.onEvent?(.phase(.connecting))
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.networkDown = false
            self.onEvent?(.phase(.connected))
            self.emitState()
        }
    }

    // MARK: Command handling (mirrors pi/dorme_coord/coordinator.py)

    private func driveBlock() -> String? {
        if benchMode { return nil }
        if !controllerLinked { return "LINK_DOWN" }
        if fault != nil { return "FAULT" }
        return nil
    }

    private func ownerAlive(_ now: Date) -> Bool {
        guard let o = owner else { return false }
        return o.leaseUntil.map { now <= $0 } ?? true
    }

    private func handle(_ c: RobotCommand) -> Ack {
        let now = clock()
        switch c.name {
        case "stop":
            let hadTask = task.map { !$0.state.isTerminal } ?? false
            dropMotion(reason: "Stopped (app)")
            epoch += 1
            stoppedAt = now
            lastStop = LastStop(at: now.timeIntervalSince1970, source: "app", reachedController: controllerLinked && !benchMode)
            emitEvent("stop", ["source": .string("app")])
            let warning: JSONValue = controllerLinked ? .null :
                .string("The motor controller is not connected, so this stop cannot reach the wheels. Use the S2 switch.")
            return Ack(id: c.id, ok: true, result: ["reached_controller": .bool(controllerLinked),
                                                    "cancelled_task": .bool(hadTask), "warning": warning])
        case "drive.claim":
            if let block = driveBlock() { return .failure(c.id, block) }
            if let t = task, !t.state.isTerminal, t.usesMotion { return .failure(c.id, "TASK_ACTIVE") }
            if ownerAlive(now), owner?.client != clientID { return .failure(c.id, "BUSY") }
            let token = "\(epoch)-\(UUID().uuidString.prefix(6))"
            owner = (clientID, token, -1, nil, now.addingTimeInterval(Double(leaseMs) / 1000))
            return Ack(id: c.id, ok: true, result: ["claim": .string(token), "lease_ms": .number(Double(leaseMs)),
                                                    "outputs": .string(benchMode ? "disabled_bench" : "enabled")])
        case "drive.hold":
            guard let d = c.args["direction"]?.string.flatMap(Direction.init(rawValue:)),
                  let s = c.args["seq"]?.int else { return .failure(c.id, "BAD_REQUEST") }
            if let block = driveBlock() { owner = nil; return .failure(c.id, block) }
            guard ownerAlive(now), var o = owner else { return .failure(c.id, "STALE") }
            guard c.args["claim"]?.string == o.claim, s > o.seq else { return .failure(c.id, "STALE") }
            o.seq = s
            o.direction = d
            o.leaseUntil = now.addingTimeInterval(Double(leaseMs) / 1000)
            owner = o
            return Ack(id: c.id, ok: true, result: ["delivered": .bool(!benchMode), "direction": .string(d.rawValue)])
        case "drive.release":
            if owner?.claim == c.args["claim"]?.string || c.args["claim"] == nil {
                if owner != nil { stoppedAt = now }
                owner = nil
            }
            return Ack(id: c.id, ok: true)
        case "task.start":
            guard let action = c.args["action"]?.string,
                  let entry = catalog().first(where: { $0.action == action }) else { return .failure(c.id, "BAD_REQUEST") }
            if let t = task, !t.state.isTerminal { return .failure(c.id, "TASK_ACTIVE") }
            guard entry.available else { return .failure(c.id, entry.unavailableCode ?? "UNAVAILABLE", entry.unavailableReason ?? "") }
            if entry.usesMotion {
                if ownerAlive(now) { return .failure(c.id, "BUSY") }
            }
            let t = startTask(entry)
            return Ack(id: c.id, ok: true, result: ["task": .string(t.id)])
        case "task.cancel":
            guard let t = task, !t.state.isTerminal else { return .failure(c.id, "NO_TASK") }
            finishTask(state: .cancelled, error: TaskError(code: "CANCELLED", message: "Cancelled (app)"))
            return Ack(id: c.id, ok: true)
        case "fault.rearm":
            guard c.args["confirm"]?.bool == true else { return .failure(c.id, "CONFIRM_REQUIRED") }
            guard let f = fault else { return .failure(c.id, "NO_FAULT") }
            guard f.phoneCanClear else { return .failure(c.id, "REARM_REFUSED", "\(f.code) needs service.") }
            fault = nil
            emitEvent("fault.cleared", [:])
            return Ack(id: c.id, ok: true, result: ["cleared": .string(f.code)])
        case "screen.note":
            let text = (c.args["text"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let seconds = c.args["seconds"]?.int ?? 0
            guard text.count <= 60, (0...4 * 3600).contains(seconds) else { return .failure(c.id, "BAD_REQUEST") }
            if text.isEmpty && seconds == 0 {
                note = nil; noteExpires = nil
                return Ack(id: c.id, ok: true)
            }
            let now = clock()
            note = ScreenNote(text: text.isEmpty ? "Timer" : text,
                              until: seconds > 0 ? now.addingTimeInterval(Double(seconds)).timeIntervalSince1970 : nil)
            noteExpires = seconds > 0 ? now.addingTimeInterval(Double(seconds) + 60) : nil
            return Ack(id: c.id, ok: true)
        case "state.get", "capabilities.get":
            return Ack(id: c.id, ok: true)
        default:
            return .failure(c.id, "UNKNOWN_COMMAND")
        }
    }

    private func dropMotion(reason: String) {
        if owner != nil { stoppedAt = clock() }
        owner = nil
        if let t = task, !t.state.isTerminal {
            finishTask(state: .cancelled, error: TaskError(code: "CANCELLED", message: reason))
        }
    }

    // MARK: Tasks

    public func catalog() -> [TaskCatalogEntry] {
        let block = driveBlock()
        func entry(_ action: String, _ title: String, _ symbol: String, _ detail: String, motion: Bool,
                   available: Bool = true, code: String? = nil, reason: String? = nil) -> TaskCatalogEntry {
            let blocked = motion && block != nil
            return TaskCatalogEntry(action: action, title: title, detail: detail, symbol: symbol, usesMotion: motion,
                                    available: available && !blocked, unavailableCode: blocked ? block : code,
                                    unavailableReason: blocked ? AckCode.message(block) : reason)
        }
        return [
            entry("greet", "Say hello", "hand.wave", "Happy face for a moment. No movement.", motion: false),
            entry("self_check", "Self check", "checklist", "Checks each subsystem and reports only what it can measure.", motion: false),
            entry("move_forward_short", "Short move forward", "arrow.up", "One bounded forward move at the slow speed.", motion: true),
            entry("turn_left_short", "Short turn left", "arrow.counterclockwise", "One short pivot.", motion: true),
            entry("turn_right_short", "Short turn right", "arrow.clockwise", "One short pivot.", motion: true),
            entry("take_photo", "Take a photo", "camera", "One still from the head camera.", motion: false,
                  available: cameraAvailable, code: "UNAVAILABLE", reason: "Camera unavailable (demo scenario)."),
            entry("go_to_desk", "Go to desk", "map", "Drive to a marked spot.", motion: true, available: false,
                  code: "UNAVAILABLE", reason: "Needs marker navigation, which is not built yet."),
        ]
    }

    private func startTask(_ entry: TaskCatalogEntry) -> RobotTask {
        let t = RobotTask(id: "demo-\(UUID().uuidString.prefix(6))", action: entry.action, title: entry.title,
                          state: .running, progress: 0, step: "Starting", source: TaskSource(kind: "app", id: clientID),
                          usesMotion: entry.usesMotion, bench: benchMode && entry.usesMotion,
                          createdAt: clock().timeIntervalSince1970, endedAt: nil, elapsedMs: 0, result: [:], error: nil)
        task = t
        if entry.usesMotion { owner = ("task", "task", 0, direction(for: entry.action), nil) }
        let duration: Double
        switch entry.action {
        case "greet": duration = 2.5
        case "self_check": duration = 3.2
        case "take_photo": duration = 1.5
        case "move_forward_short": duration = 2.0
        default: duration = 0.8
        }
        if entry.action == "greet" { transientFace = ("happy", clock().addingTimeInterval(2.5)) }
        taskRunner?.cancel()
        taskRunner = Task { [weak self] in
            let steps = Int(duration / 0.2)
            for i in 1...max(1, steps) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, !Task.isCancelled, var cur = self.task, cur.id == t.id, !cur.state.isTerminal else { return }
                cur.progress = Double(i) / Double(steps)
                cur.step = self.stepText(entry.action, cur.progress ?? 0)
                cur.elapsedMs = i * 200
                self.task = cur
                self.emitTaskEvent()
            }
            guard let self, self.task?.id == t.id, self.task?.state == .running else { return }
            self.finishTask(state: .succeeded, result: self.result(for: entry.action))
        }
        emitTaskEvent()
        return t
    }

    private func direction(for action: String) -> Direction? {
        switch action {
        case "move_forward_short": return .forward
        case "turn_left_short": return .left
        case "turn_right_short": return .right
        default: return nil
        }
    }

    private func stepText(_ action: String, _ p: Double) -> String {
        switch action {
        case "self_check": return p < 0.3 ? "Checking controller link" : p < 0.6 ? "Checking battery voltage" : "Checking camera and audio"
        case "greet": return "Smiling"
        case "take_photo": return "Capturing"
        default: return benchMode ? "Bench rehearsal (no motor output)" : "Moving (commanded, simulated)"
        }
    }

    private func result(for action: String) -> [String: JSONValue] {
        switch action {
        case "self_check":
            func item(_ n: String, _ s: String, _ d: String) -> JSONValue {
                .object(["name": .string(n), "status": .string(s), "detail": .string(d)])
            }
            let checks: [JSONValue] = [
                item("Coordinator", "ok", "Demo mode. No robot is connected."),
                item("Face display", "ok", "Simulated."),
                item("Motor controller link", controllerLinked ? "ok" : "unavailable", controllerLinked ? "Simulated ESP32 in READY." : "Simulated link lost."),
                item("Battery voltage", "ok", String(format: "%.2f V at the logic rail (simulated).", voltage)),
                item("Sonar", "ok", "120 cm (simulated)."),
                item("Camera", cameraAvailable ? "ok" : "unavailable", cameraAvailable ? "Simulated test frames." : "Unavailable (demo scenario)."),
                item("Audio", "unavailable", "Playback not connected yet."),
                item("Bluetooth", "unavailable", "Demo does not use Bluetooth."),
                item("Motor outputs", benchMode ? "warn" : "ok", benchMode ? "Disabled (bench mode)." : "Simulated."),
            ]
            return ["summary": .string("6 of 9 subsystems answered (simulated)."), "checks": .array(checks)]
        case "greet":
            return ["summary": .string("Showed the happy face."), "note": .string("No chime: audio playback is not connected yet.")]
        case "take_photo":
            return ["summary": .string("Photo taken (simulated test card)."), "simulated": .bool(true)]
        default:
            return benchMode ? ["summary": .string("Bench rehearsal finished."), "note": .string("Bench mode: no motor output was sent.")]
                : ["summary": .string("Move finished on time (commanded, simulated).")]
        }
    }

    private func finishTask(state: TaskState, result: [String: JSONValue] = [:], error: TaskError? = nil) {
        guard var t = task, !t.state.isTerminal else { return }
        t.state = state
        t.endedAt = clock().timeIntervalSince1970
        t.result.merge(result) { $1 }
        t.error = error
        t.step = state == .succeeded ? "Done" : state == .cancelled ? "Cancelled" : "Failed"
        if state == .succeeded { t.progress = 1 }
        task = t
        if t.usesMotion, owner?.client == "task" { owner = nil; stoppedAt = clock() }
        taskRunner?.cancel()
        history.insert(t, at: 0)
        history = Array(history.prefix(10))
        if state == .succeeded && t.action != "greet" { transientFace = ("happy", clock().addingTimeInterval(1)) }
        emitTaskEvent()
        emitTasks()
    }

    // MARK: Tick and emission

    private func tick(emit: Bool) {
        let now = clock()
        if let o = owner, let until = o.leaseUntil, now > until {
            owner = nil                       // lease expired: holds stopped arriving
            stoppedAt = now
            emitEvent("drive.owner", ["reason": .string("Hold expired")])
            emitState()
            return
        }
        if !lowBattery { voltage = 9.62 + Double.random(in: -0.02...0.02) }
        if emit { emitState() }
    }

    private func emitEvent(_ kind: String, _ body: [String: JSONValue]) {
        guard !networkDown else { return }
        var b = body
        b["kind"] = .string(kind)
        onEvent?(.event(RobotEvent(kind: kind, body: b)))
    }

    private func emitTaskEvent() {
        guard let t = task else { return }
        emitEvent("task.updated", [:])
        if !networkDown { onEvent?(.state(makeState(), receivedAt: clock())) }
        _ = t
    }

    private func emitTasks() {
        guard !networkDown else { return }
        onEvent?(.tasks(TaskList(catalog: catalog(), current: task, history: history)))
    }

    private func emitState() {
        guard connected, !networkDown else { return }
        onEvent?(.state(makeState(), receivedAt: clock()))
    }

    public func makeState() -> RobotState {
        seq += 1
        let now = clock()
        let moving = !benchMode && controllerLinked && owner?.direction != nil && fault == nil
        let block = driveBlock()
        if let e = noteExpires, now >= e { note = nil; noteExpires = nil }
        let faceName: String = {
            // same order as the robot (coordinator.compute_face): a requested look and the owner's note
            // show over a standing fault
            if let tf = transientFace, now < tf.until { return tf.name }
            if note != nil { return "note" }
            if let f = fault { return f.code == "LOW_BUS" ? "low_energy" : "fault" }
            if !controllerLinked { return "fault" }
            if owner != nil { return "moving" }
            if lowBattery { return "low_energy" }
            return "idle"
        }()
        let activeFault: FaultInfo? = fault ?? (controllerLinked ? nil : DemoRobot.fault("LINK_LOST"))
        let underLoad = moving || now.timeIntervalSince(stoppedAt) < 5
        return RobotState(
            seq: seq,
            robot: RobotInfo(name: "DORM-E", mode: "demo", simulated: true, software: "demo", api: 1,
                             benchMode: benchMode, backend: "demo"),
            connection: ConnectionInfo(esp32: controllerLinked ? "up" : "lost", espState: controllerLinked ? (moving ? "MOVING" : "READY") : nil,
                                       statAgeMs: controllerLinked ? 60 : nil, hbGapMaxMs: controllerLinked ? 104 : nil,
                                       linkdDryRun: nil, firmware: "demo", resetReason: "POWERON"),
            battery: Battery(voltageV: controllerLinked ? (voltage * 100).rounded() / 100 : nil,
                             voltageReason: controllerLinked ? nil : "No status from the motor controller (ESP32).",
                             basis: "INA219 bus voltage at the logic rail", ageMs: controllerLinked ? 60 : nil,
                             underLoad: underLoad, percent: nil,
                             percentReason: "Not calibrated. Needs the discharge log (bench test B22).",
                             low: controllerLinked ? lowBattery : nil, lowThresholdV: 9.0, lowBasis: "simulated threshold",
                             simulated: true),
            motion: Motion(state: moving ? "moving" : "stopped", direction: moving ? owner?.direction?.rawValue : nil,
                           basis: "commanded",
                           owner: owner.map { MotionOwner(source: $0.client == "task" ? "task" : "app", client: $0.client, direction: $0.direction?.rawValue) },
                           outputs: benchMode ? "disabled_bench" : "enabled", driveAllowed: block == nil,
                           driveBlock: block, driveBlockMessage: block.map { AckCode.message($0) }, lastStop: lastStop),
            task: task,
            fault: FaultBlock(active: activeFault, lastOffForced: false),
            power: Power(plug: controllerLinked ? false : nil, shuttingDown: nil, motorRailOn: controllerLinked && !benchMode, motorRailV: nil),
            face: FaceInfo(state: faceName, adapter: "simulated", adapterReason: "Demo face drawn by the app."),
            peripherals: Peripherals(
                camera: Peripheral(status: cameraAvailable ? "simulated" : "unavailable",
                                   reason: cameraAvailable ? "Demo camera: synthetic picture." : "Camera unavailable (demo scenario)."),
                audio: Peripheral(status: "unavailable", reason: "Playback not connected yet."),
                ble: Peripheral(status: "unavailable", reason: "Demo does not use Bluetooth."),
                sonar: Peripheral(status: controllerLinked ? "simulated" : "unavailable", reason: controllerLinked ? nil : "No fresh controller status.",
                                  distanceCm: controllerLinked ? 120 : nil)),
            network: NetworkInfo(trust: "private", wifiSsid: "Demo Wi-Fi", wifiDbm: -52, ipv4: ["demo"],
                                 remote: RemoteInfo(online: false)),
            health: demoHealth(activeFault: activeFault),
            screen: ScreenInfo(note: note),
            notMeasured: ["current", "runtime", "temperature", "motor_rpm", "charging_status", "wheel_speed"])
    }

    /// Per-part health in the same shape the real robot sends (pi/dorme_coord/health.py).
    func demoHealth(activeFault: FaultInfo?) -> HealthSummary {
        var parts: [String: PartHealth] = [
            "PI4": PartHealth(s: "ok", t: "48°C"), "WIFI": PartHealth(s: "ok", t: "Demo Wi-Fi"),
            "BLUETOOTH": PartHealth(s: "ok", t: "Simulated"), "REMOTE": PartHealth(s: "off", t: "Not set up"),
            "ESP32_U7": PartHealth(s: controllerLinked ? "ok" : "fault", t: controllerLinked ? "Linked" : "Link lost"),
            "INA219_U9": PartHealth(s: controllerLinked ? "ok" : "off", t: controllerLinked ? String(format: "%.2f V", voltage) : "No data"),
            "BATTERY": PartHealth(s: lowBattery ? "warn" : "ok", t: String(format: "%.1f V", voltage)),
            "U15": PartHealth(s: benchMode ? "off" : "ok", t: benchMode ? "Motor rail off" : "Motor rail on"),
            "SONAR": PartHealth(s: controllerLinked ? "ok" : "off", t: controllerLinked ? "120 cm" : "No data"),
            "LCD": PartHealth(s: "ok", t: "Face running"),
            "CAMERA": PartHealth(s: cameraAvailable ? "ok" : "off", t: cameraAvailable ? "Simulated" : "Not connected"),
            "AUDIO_U16": PartHealth(s: "off", t: "Not connected"),
            "S2_SWITCH": PartHealth(s: "ok", t: "On"), "J_CHG": PartHealth(s: "ok", t: "Unplugged"),
        ]
        for id in ["M1", "M2", "M3", "M4", "MD20A_U4", "MD20A_U5", "XL4005_U2", "XL4005_U3", "FAN", "U1", "U14",
                   "DCB", "SPEAKER", "TH1", "K2_RELAY", "FUSE_F0", "FUSE_F1", "FUSE_F2", "FUSE_F3", "FUSE_F4"] {
            parts[id] = PartHealth(s: "none", t: "No sensor")
        }
        if let f = activeFault {
            let target = f.code == "JAM" ? "M2" : "ESP32_U7"
            parts[target] = PartHealth(s: f.code == "JAM" ? "warn" : "fault", t: f.title)
        }
        let issues = parts.filter { $0.value.s == "fault" || $0.value.s == "warn" }
            .map { HealthIssue(id: $0.key, status: $0.value.s, text: $0.value.t) }
            .sorted { a, b in
                let ra = a.status == "fault" ? 0 : 1, rb = b.status == "fault" ? 0 : 1
                return ra != rb ? ra < rb : a.id < b.id
            }
        let overall = issues.contains { $0.status == "fault" } ? "fault" : (issues.isEmpty ? "ok" : "warn")
        return HealthSummary(overall: overall, headline: issues.first?.text ?? "Operational", issues: issues, parts: parts)
    }

    public func capabilities() -> Capabilities {
        Capabilities(apiVersion: 1, commands: ["stop", "drive.claim", "drive.hold", "drive.release", "task.start",
                                               "task.cancel", "fault.rearm", "state.get", "capabilities.get", "screen.note"],
                     drive: DriveCaps(directions: ["F", "B", "L", "R"], holdToDrive: true, speedLevelsPct: [30], turnSpeedPct: 60,
                                      speedNote: "Phone speed is fixed at SPEED_LOW in V1. Firmware caps PWM at 60 %.",
                                      holdLeaseMs: leaseMs, holdIntervalMs: 200),
                     tasks: catalog(),
                     battery: BatteryCaps(voltage: true, percent: false, basis: "INA219 bus voltage at the logic rail"),
                     camera: CameraCaps(streamPath: nil, snapshotPath: nil, orientation: "portrait", rotationDeg: nil, rotationVerified: false),
                     ble: nil, staleness: Staleness(staleAfterMs: 3000, offlineAfterMs: 10000),
                     notMeasured: ["current", "runtime", "temperature", "motor_rpm", "charging_status", "wheel_speed"])
    }

    static func fault(_ code: String) -> FaultInfo {
        switch code {
        case "STALE": return FaultInfo(code: code, title: "Command expired", detail: "A drive command arrived too late; wheels stopped.", rearm: "phone_or_voice")
        case "JAM": return FaultInfo(code: code, title: "Possible jam", detail: "Sonar range did not change while driving straight.", rearm: "phone_or_voice")
        case "RAIL_LIVE": return FaultInfo(code: code, title: "Motor rail live while disabled", detail: "U15 or Q2 suspect. Service needed.", rearm: "service")
        case "LINK_LOST": return FaultInfo(code: code, title: "Controller link lost", detail: "No status from the ESP32. Stop cannot reach the wheels: use S2.", rearm: "auto")
        default: return FaultInfo(code: code, title: code, detail: "Simulated fault.", rearm: "phone_or_voice")
        }
    }
}
