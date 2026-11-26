import Network
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
        case home, control, tasks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Robot"
            case .control: return "Drive"
            case .tasks: return "Tasks"
            }
        }
        var symbol: String {
            switch self {
            case .home: return "cube.transparent"
            case .control: return "dpad"
            case .tasks: return "checklist"
            }
        }
    }

    /// Where automatic connection stands (the home page shows it inline; there is no connect sheet).
    enum ConnectState: Equatable { case idle, searching, notFound }

    var tab: Tab = .home
    /// Kept for older call sites: asking for the connect screen now just goes to the home page.
    var showConnect = false { didSet { if showConnect { tab = .home; showConnect = false } } }
    var showDemoControls = false
    private(set) var connectState: ConnectState = .idle
    private(set) var system: SystemReport?
    private(set) var lastQR: PairingQR?
    let discovery = Discovery()
    let ble = BLEScanner()

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
    @ObservationIgnored private var searchTask: Task<Void, Never>?
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
        var h = host.trimmingCharacters(in: .whitespaces)
        var port = port
        // accept "http://host:port/..." and "host:port" (not bare IPv6 addresses, which have several colons)
        for scheme in ["http://", "https://", "ws://", "wss://"] where h.lowercased().hasPrefix(scheme) {
            h.removeFirst(scheme.count)
        }
        if !h.hasPrefix("["), let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {        // [v6]:port
            let rest = h[h.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()), (1...65535).contains(p) { port = p }
            h = String(h[h.index(after: h.startIndex)..<close])
        } else if h.filter({ $0 == ":" }).count == 1, let i = h.lastIndex(of: ":"),
                  let p = Int(h[h.index(after: i)...]), (1...65535).contains(p) {
            port = p
            h = String(h[..<i])
        }
        guard !h.isEmpty else { return }
        searchTask?.cancel()
        connectState = .idle
        defaults.set(h, forKey: "robot.host")
        defaults.set(port, forKey: "robot.port")
        attach(NetworkRobotClient(host: h, port: port))
    }

    /// Every address worth trying, best first: Bonjour on this network, the address typed last, the robot's
    /// last Wi-Fi address, then its Tailscale name and address (reachable from anywhere once set up), then the
    /// default names: dorm-e.local on this network and dorm-e through Tailscale (MagicDNS).
    var candidateHosts: [String] {
        var list = discovery.hosts
        for key in ["robot.host", "robot.lanIP", "robot.remoteName", "robot.remoteIP"] {
            if let h = defaults.string(forKey: key), !h.isEmpty { list.append(h) }
        }
        list.append("dorm-e.local")
        list.append("dorm-e")
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// Find the robot without asking: browse Bonjour and probe every known address at once, six rounds (~25 s),
    /// so an address that is not up yet (Tailscale still connecting) gets another chance.
    func autoConnect() {
        guard client == nil || phase != .connected else { return }
        searchTask?.cancel()
        lastSearch = Date()
        connectState = .searching
        discovery.start()
        ble.start()
        startPathMonitor()
        let port = savedPort
        searchTask = Task { [weak self] in
            for round in 0..<6 {
                guard let hosts = self?.candidateHosts, !Task.isCancelled else { return }
                let found: String? = await withTaskGroup(of: String?.self) { group in
                    for host in hosts {
                        group.addTask { await NetworkRobotClient.probe(host: host, port: port, timeout: 3) ? host : nil }
                    }
                    for await hit in group where hit != nil {
                        group.cancelAll()            // first address that answers wins
                        return hit
                    }
                    return nil
                }
                guard let self, !Task.isCancelled else { return }
                if let found {
                    self.connect(host: found, port: port)
                    return
                }
                if round < 5 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            if !Task.isCancelled { self?.connectState = .notFound }
        }
    }

    @ObservationIgnored private var lastSearch = Date.distantPast
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    /// The phone changed network (Wi-Fi to cellular, VPN on): look for the robot again on whatever path works now.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, !self.isDemo, self.phase != .connected, self.connectState != .searching else { return }
                self.autoConnect()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    func cancelSearch() {
        searchTask?.cancel()
        if connectState == .searching { connectState = .notFound }
    }

    /// Remember where the robot is, so it can be found again on another network.
    private func remember(_ s: RobotState) {
        if let ip = s.network.ipv4?.first { defaults.set(ip, forKey: "robot.lanIP") }
        if let r = s.network.remote, r.online {
            if let name = r.name { defaults.set(name, forKey: "robot.remoteName") }
            if let ip = r.ips?.first { defaults.set(ip, forKey: "robot.remoteIP") }
        }
    }

    // MARK: Robot system (V1 closed-robot operations)

    func refreshSystem() async {
        guard let network else { return }
        if let report = await network.getJSON("api/v1/system", as: SystemReport.self) { system = report }
    }

    func wifiStatus() async -> WifiStatus? { await network?.getJSON("api/v1/network/wifi", as: WifiStatus.self) }
    func wifiScan() async -> [VisibleNetwork] { await network?.getJSON("api/v1/network/wifi/scan", as: WifiScan.self, timeout: 30)?.networks ?? [] }

    func addWifi(ssid: String, password: String, username: String?, domain: String?, joinNow: Bool) async -> Ack {
        guard let network else { return .failure(nil, "OFFLINE") }
        var body: [String: Any] = ["ssid": ssid, "connect": joinNow]
        if let username, !username.isEmpty {
            var eap: [String: Any] = ["identity": username, "password": password]
            if let domain, !domain.isEmpty { eap["domain"] = domain }
            body["eap"] = eap
        } else if !password.isEmpty {
            body["psk"] = password
        }
        return await network.post("api/v1/network/wifi", body: body, timeout: 30)
    }

    func forgetWifi(_ ssid: String) async -> Ack {
        await network?.post("api/v1/network/wifi/forget", body: ["ssid": ssid]) ?? .failure(nil, "OFFLINE")
    }

    func enableRemote() async -> Ack {
        await network?.post("api/v1/remote/enable", timeout: 45) ?? .failure(nil, "OFFLINE")
    }

    func restartService(_ unit: String) async -> Ack {
        await network?.post("api/v1/system/restart", body: ["unit": unit]) ?? .failure(nil, "OFFLINE")
    }

    func power(_ action: String) async -> Ack {      // "reboot" or "poweroff"
        await network?.post("api/v1/system/\(action)", body: ["confirm": true]) ?? .failure(nil, "OFFLINE")
    }

    /// Pair with a scanned QR: its 6 digits pair over Wi-Fi; the QR is kept for Bluetooth Wi-Fi setup.
    func pair(qr: PairingQR) async -> Ack {
        lastQR = qr
        return await pair(pin: qr.code)
    }

    func rememberQR(_ qr: PairingQR) { lastQR = qr }

    func disconnect() {
        drive?.reset()
        let old = client
        old?.onEvent = nil                 // a replaced client must never change this store again
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
            if p == .connected { connectState = .idle }
            if p != .connected { drive?.reset() }        // a lost socket never keeps a hold going
            if case .offline(let why) = p {
                show(why, .warn)
                // the address may have changed (new Wi-Fi, away from home): search every path, at most every 30 s
                if !isDemo && connectState != .searching && Date().timeIntervalSince(lastSearch) > 30 { autoConnect() }
            }
        case .state(let s, let at):
            state = s
            lastMessageAt = at
            remember(s)
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
