import SwiftUI
import DORMEKit

/// App-wide state. Holds exactly one RobotClient: the isolated DemoRobot or the Wi-Fi
/// NetworkRobotClient, never both. Every view reads from here and every action goes through here.
@MainActor
@Observable
final class RobotStore {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var level: Level
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case home, control, tasks, robot
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Home"
            case .control: return "Control"
            case .tasks: return "Tasks"
            case .robot: return "Robot"
            }
        }
        var symbol: String {
            switch self {
            case .home: return "house"
            case .control: return "dpad"
            case .tasks: return "checklist"
            case .robot: return "cpu"
            }
        }
    }

    var tab: Tab = .home
    var showConnect = false
    var showDemoControls = false

    private(set) var client: RobotClient?
    private(set) var phase: ConnectionPhase = .idle
    private(set) var state: RobotState?
    private(set) var lastMessageAt: Date?
    private(set) var capabilities: Capabilities?
    private(set) var tasks: TaskList?
    private(set) var driveStatus: DriveSession.Status = .idle
    private(set) var now = Date()
    var toast: Toast?

    @ObservationIgnored private var drive: DriveSession?
    @ObservationIgnored private var clock: Task<Void, Never>?
    @ObservationIgnored let defaults = UserDefaults.standard

    init() {
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.now = Date()
            }
        }
    }

    // MARK: Derived

    var isDemo: Bool { client?.isDemo ?? false }
    var demo: DemoRobot? { client as? DemoRobot }
    var network: NetworkRobotClient? { client as? NetworkRobotClient }
    var hasClient: Bool { client != nil }

    var freshness: Freshness {
        let policy = capabilities.map { FreshnessPolicy($0.staleness) } ?? FreshnessPolicy()
        return policy.evaluate(lastMessage: lastMessageAt, now: now, socketOpen: phase == .connected)
    }

    /// True when shown values must be greyed (stale, offline, connecting).
    var dimmed: Bool { !freshness.isLive }

    var savedHost: String { defaults.string(forKey: "robot.host") ?? "dorm-e.local" }
    var savedPort: Int { let p = defaults.integer(forKey: "robot.port"); return p == 0 ? 8080 : p }

    // MARK: Connection

    func startDemo() {
        attach(DemoRobot())
    }

    func connect(host: String, port: Int) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        defaults.set(h, forKey: "robot.host")
        defaults.set(port, forKey: "robot.port")
        attach(NetworkRobotClient(host: h, port: port))
    }

    func disconnect() {
        drive?.reset()
        let old = client
        client = nil
        state = nil
        tasks = nil
        capabilities = nil
        lastMessageAt = nil
        phase = .idle
        Task { await old?.disconnect() }
    }

    private func attach(_ newClient: RobotClient) {
        disconnect()
        client = newClient
        newClient.onEvent = { [weak self] event in self?.handle(event) }
        let session = DriveSession { [weak newClient] command in
            guard let c = newClient else { return .failure(command.id, "OFFLINE") }
            return await c.send(command)
        }
        session.onChange = { [weak self] status in
            self?.driveStatus = status
            if case .refused(_, let message) = status { self?.show(message, .warn) }
        }
        drive = session
        Task { await newClient.connect() }
    }

    func pair(pin: String) async -> Ack {
        guard let client else { return .failure(nil, "OFFLINE") }
        return await client.pair(pin: pin)
    }

    func showPairingCode() async -> Ack {
        guard let client else { return .failure(nil, "OFFLINE") }
        return await client.showPairingCode()
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .phase(let p):
            phase = p
            if p != .connected { drive?.reset() }        // a lost socket never keeps a hold going
            if case .offline(let why) = p { show(why, .warn) }
        case .state(let s, let at):
            state = s
            lastMessageAt = at
        case .capabilities(let c):
            capabilities = c
            drive?.setInterval(ms: c.drive.holdIntervalMs)
        case .event(let e):
            onRobotEvent(e)
        case .tasks(let list):
            tasks = list
        }
    }

    private func onRobotEvent(_ e: RobotEvent) {
        switch e.kind {
        case "fault.raised":
            drive?.reset()
            show("Fault: \(e.body["fault"]?["title"]?.string ?? e.body["code"]?.string ?? "check Home")", .bad)
        case "drive.owner":
            if let reason = e.body["reason"]?.string, reason == "Hold expired", drive?.activeDirection != nil {
                drive?.reset()
            }
        case "controller.boot":
            drive?.reset()
            show("Motor controller restarted. Nothing resumes by itself.", .warn)
        default:
            break
        }
    }

    // MARK: Actions

    func stop() {
        drive?.reset()
        guard let client else {
            show("Not connected. Use the S2 switch on the robot.", .bad)
            return
        }
        Task {
            let ack = await client.stop()
            if ack.ok {
                if let warning = ack.result.lookup("warning")?.string { show(warning, .warn) }
                else { show(isDemo ? "Stopped (demo)." : "Stopped.", .good) }
            } else {
                show(ack.message, .bad)
            }
        }
    }

    func press(_ d: Direction) {
        guard hasClient else { return }
        drive?.clearRefusal()
        drive?.press(d)
    }

    func release() { drive?.release() }

    func backgrounded() {
        // Leaving the app must never leave a hold running.
        drive?.release()
    }

    func startTask(_ action: String) {
        guard let client else { return }
        Task {
            let ack = await client.send(.startTask(action))
            if !ack.ok { show(ack.message, .warn) }
            await client.refreshTasks()
        }
    }

    func cancelTask() {
        guard let client else { return }
        Task {
            let ack = await client.send(.cancelTask(state?.task?.id))
            if !ack.ok { show(ack.message, .warn) }
            await client.refreshTasks()
        }
    }

    func rearm() {
        guard let client else { return }
        Task {
            let ack = await client.send(.rearm())
            show(ack.ok ? "Fault cleared. The next move still needs a new command." : ack.message, ack.ok ? .good : .warn)
        }
    }

    func show(_ text: String, _ level: Level) {
        toast = Toast(text: text, level: level)
        let id = toast?.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.toast?.id == id { self?.toast = nil }
        }
    }
}
