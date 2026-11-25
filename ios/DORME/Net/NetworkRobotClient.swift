import Foundation
import Security
import DORMEKit

/// The real robot over Wi-Fi: HTTP for info/pair/stop/tasks, one WebSocket for state, events and
/// commands. It never invents data: when the socket is down it reports offline and every command
/// except stop fails with OFFLINE. Stop goes over plain HTTP first because that path needs no
/// pairing and no open socket.
@MainActor
final class NetworkRobotClient: RobotClient {
    let isDemo = false
    let host: String
    let port: Int
    var displayName: String { "\(host):\(port)" }
    var onEvent: ((ClientEvent) -> Void)?

    private let session: URLSession
    private var token: String?
    private var ws: URLSessionWebSocketTask?
    private var pending: [String: CheckedContinuation<Ack, Never>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var wantConnected = false
    private var backoff: Double = 1
    private var socketOpen = false

    init(host: String, port: Int = 8080) {
        self.host = host
        self.port = port
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.token = Keychain.read(account: "\(host):\(port)")
    }

    private var base: URL { URL(string: Self.origin(host: host, port: port, scheme: "http"))! }

    /// http://host:port, bracketing IPv6 literals.
    static func origin(host: String, port: Int, scheme: String) -> String {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(h):\(port)"
    }

    /// Quick check that a DORM-E answers at host:port (used to pick among discovered/remembered addresses).
    static func probe(host: String, port: Int, timeout: Double = 3) async -> Bool {
        guard let url = URL(string: origin(host: host, port: port, scheme: "http") + "/api/v1/info") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        guard let (data, response) = try? await URLSession(configuration: config).data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return obj["name"] as? String == "DORM-E"
    }

    /// Authenticated GET decoded with the shared decoder; nil on any failure.
    func getJSON<T: Decodable>(_ path: String, as type: T.Type, timeout: Double = 10) async -> T? {
        guard let (data, response) = try? await session.data(for: request(path, timeout: timeout)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? DORMEJSON.decoder.decode(T.self, from: data)
    }

    /// Authenticated POST answered with an ack.
    func post(_ path: String, body: [String: Any] = [:], timeout: Double = 15) async -> Ack {
        do {
            let (data, _) = try await session.data(for: request(path, method: "POST", body: body, timeout: timeout))
            return try DORMEJSON.decoder.decode(Ack.self, from: data)
        } catch {
            return .failure(nil, "OFFLINE", "Can't reach the robot.")
        }
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: Double = 5) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // URLSessionWebSocketTask drops Authorization on the upgrade (reserved header); the robot also reads this.
            req.setValue(token, forHTTPHeaderField: "X-DORME-Token")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Authenticated request for the MJPEG camera stream.
    func cameraRequest(path: String) -> URLRequest {
        var req = request(path, timeout: 10)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    // MARK: Connection

    func connect() async {
        wantConnected = true
        reconnectTask?.cancel()
        onEvent?(.phase(.connecting))
        struct Info: Decodable { var api: Int; var mode: String; var simulated: Bool; var paired: Bool }
        do {
            let (data, response) = try await session.data(for: request("api/v1/info", timeout: 8))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                onEvent?(.phase(.unavailable("\(host) answered, but not as a DORM-E robot.")))
                return
            }
            let info = try JSONDecoder().decode(Info.self, from: data)
            guard info.api == 1 else {
                onEvent?(.phase(.unavailable("The robot speaks API v\(info.api); this app speaks v1.")))
                return
            }
            if !info.paired { token = nil }
        } catch {
            let code = (error as? URLError)?.code.rawValue
            onEvent?(.phase(.offline("Can't reach \(host)\(code.map { " (\($0))" } ?? "")")))
            scheduleReconnect()
            return
        }
        guard token != nil else {
            onEvent?(.phase(.pairingRequired))
            return
        }
        openSocket()
    }

    func disconnect() async {
        wantConnected = false
        reconnectTask?.cancel()
        closeSocket(reason: nil)
        onEvent?(.phase(.idle))
    }

    private func openSocket() {
        closeSocket(reason: nil)
        var req = request("api/v1/ws", timeout: 5)
        req.url = URL(string: Self.origin(host: host, port: port, scheme: "ws") + "/api/v1/ws")
        let task = session.webSocketTask(with: req)
        ws = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                task.sendPing { _ in }
                _ = self
            }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                handle(data)
            } catch {
                guard ws === task else { return }
                let status = (task.response as? HTTPURLResponse)?.statusCode
                if status == 401 {
                    token = nil
                    Keychain.delete(account: displayName)
                    closeSocket(reason: nil)
                    onEvent?(.phase(.pairingRequired))
                } else {
                    let detail = (error as? URLError).map { "error \($0.code.rawValue)" } ?? error.localizedDescription
                    let http = status.map { ", HTTP \($0)" } ?? ""
                    closeSocket(reason: "Connection to the robot was lost (\(detail)\(http)).")
                    scheduleReconnect()
                }
                return
            }
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? ServerMessage.decode(data) else { return }
        switch message {
        case .hello(_, let state, let caps):
            socketOpen = true
            backoff = 1
            onEvent?(.phase(.connected))
            onEvent?(.capabilities(caps))
            onEvent?(.state(state, receivedAt: Date()))
            Task { await refreshTasks() }
        case .state(let state):
            onEvent?(.state(state, receivedAt: Date()))
        case .event(let event):
            onEvent?(.event(event))
            if event.kind == "task.updated", let s = event.body["task"]?["state"]?.string,
               ["succeeded", "failed", "cancelled"].contains(s) {
                Task { await refreshTasks() }
            }
        case .ack(let ack):
            if let id = ack.id, let cont = pending.removeValue(forKey: id) { cont.resume(returning: ack) }
        case .unknown:
            break
        }
    }

    private func closeSocket(reason: String?) {
        receiveTask?.cancel()
        pingTask?.cancel()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        let wasOpen = socketOpen
        socketOpen = false
        for (id, cont) in pending { cont.resume(returning: .failure(id, "OFFLINE")) }
        pending.removeAll()
        if let reason, wasOpen || wantConnected { onEvent?(.phase(.offline(reason))) }
    }

    private func scheduleReconnect() {
        guard wantConnected else { return }
        reconnectTask?.cancel()
        let delay = backoff
        backoff = min(backoff * 2, 10)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.wantConnected else { return }
            await self.connect()
        }
    }

    // MARK: Commands

    func pair(pin: String) async -> Ack {
        do {
            let (data, _) = try await session.data(for: request("api/v1/pair", method: "POST",
                                                                body: ["pin": pin, "client_name": "iPhone"]))
            let ack = try DORMEJSON.decoder.decode(Ack.self, from: data)
            if ack.ok, let t = ack.result.lookup("token")?.string {
                token = t
                Keychain.save(t, account: displayName)
                openSocket()
            }
            return ack
        } catch {
            return .failure(nil, "OFFLINE", "Can't reach the robot to pair.")
        }
    }

    func showPairingCode() async -> Ack {
        do {
            let (data, _) = try await session.data(for: request("api/v1/pair/show", method: "POST", body: [:]))
            return try DORMEJSON.decoder.decode(Ack.self, from: data)
        } catch {
            return .failure(nil, "OFFLINE", "Can't reach the robot to show a code.")
        }
    }

    func send(_ command: RobotCommand) async -> Ack {
        guard let ws, socketOpen, let data = try? command.wireData(), let text = String(data: data, encoding: .utf8) else {
            return .failure(command.id, "OFFLINE")
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Ack, Never>) in
            pending[command.id] = cont
            ws.send(.string(text)) { _ in }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, let c = self.pending.removeValue(forKey: command.id) else { return }
                c.resume(returning: .failure(command.id, "TIMEOUT"))
            }
        }
    }

    func stop() async -> Ack {
        // 1. Plain HTTP: works unpaired and without the socket.
        if let reply = try? await session.data(for: request("api/v1/stop", method: "POST", body: [:], timeout: 2)),
           let ack = try? DORMEJSON.decoder.decode(Ack.self, from: reply.0) {
            return ack
        }
        // 2. The socket, if it is still up.
        let viaSocket = await send(.stop())
        if viaSocket.ok { return viaSocket }
        return .failure(nil, "OFFLINE", "Stop could not reach the robot. Use the S2 switch on the robot.")
    }

    func refreshTasks() async {
        guard token != nil,
              let reply = try? await session.data(for: request("api/v1/tasks")),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let list = try? DORMEJSON.decoder.decode(TaskList.self, from: reply.0) else { return }
        onEvent?(.tasks(list))
    }
}

/// Session tokens live in the Keychain, one per robot address. The PIN is never stored.
enum Keychain {
    static let service = "DORM-E robot session"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
