import Foundation

// Commands, acknowledgements, server messages and the transport-independent client protocol.

public enum Direction: String, CaseIterable, Sendable {
    case forward = "F", back = "B", left = "L", right = "R"
    public var label: String {
        switch self {
        case .forward: return "Forward"
        case .back: return "Back"
        case .left: return "Turn left"
        case .right: return "Turn right"
        }
    }
    public var symbol: String {
        switch self {
        case .forward: return "arrow.up"
        case .back: return "arrow.down"
        case .left: return "arrow.counterclockwise"
        case .right: return "arrow.clockwise"
        }
    }
}

public struct RobotCommand: Sendable, Equatable {
    public var id: String
    public var name: String
    public var args: [String: JSONValue]

    public init(_ name: String, _ args: [String: JSONValue] = [:], id: String = RobotCommand.newID()) {
        self.id = id; self.name = name; self.args = args
    }

    public static func newID() -> String { "ios-" + UUID().uuidString.prefix(8).lowercased() }

    public static func stop() -> RobotCommand { .init("stop") }
    public static func claim() -> RobotCommand { .init("drive.claim") }
    public static func hold(claim: String, direction: Direction, seq: Int) -> RobotCommand {
        .init("drive.hold", ["claim": .string(claim), "direction": .string(direction.rawValue), "seq": .number(Double(seq))])
    }
    public static func release(claim: String?) -> RobotCommand {
        .init("drive.release", claim.map { ["claim": .string($0)] } ?? [:])
    }
    public static func startTask(_ action: String) -> RobotCommand { .init("task.start", ["action": .string(action)]) }
    public static func cancelTask(_ id: String?) -> RobotCommand {
        .init("task.cancel", id.map { ["task_id": .string($0)] } ?? [:])
    }
    public static func rearm() -> RobotCommand { .init("fault.rearm", ["confirm": .bool(true)]) }

    /// Wire form: {"v":1,"type":"command","id":..,"name":..,"args":{..}}. Keys are written as-is.
    public func wireData() throws -> Data {
        let envelope: [String: JSONValue] = ["v": .number(1), "type": .string("command"), "id": .string(id),
                                              "name": .string(name), "args": .object(args)]
        return try DORMEJSON.encoder.encode(envelope)
    }
}

public struct Ack: Codable, Equatable, Sendable {
    public var v: Int
    public var type: String
    public var id: String?
    public var ok: Bool
    public var code: String?
    public var message: String
    public var result: [String: JSONValue]

    public init(id: String?, ok: Bool, code: String? = nil, message: String = "", result: [String: JSONValue] = [:]) {
        self.v = 1; self.type = "ack"; self.id = id; self.ok = ok; self.code = code
        self.message = message.isEmpty && !ok ? AckCode.message(code) : message
        self.result = result
    }

    public static func failure(_ id: String?, _ code: String, _ message: String = "") -> Ack {
        Ack(id: id, ok: false, code: code, message: message)
    }
}

public enum AckCode {
    public static let messages: [String: String] = [
        "UNAUTHORIZED": "Pair with the robot first.",
        "BAD_REQUEST": "The request was malformed.",
        "UNKNOWN_COMMAND": "The robot does not know this command.",
        "RATE_LIMITED": "Too many messages; slow down.",
        "LOCKED_OUT": "Too many wrong PINs; wait and try again.",
        "BAD_PIN": "That PIN is not correct.",
        "BUSY": "Another controller or task owns movement.",
        "NOT_OWNER": "This controller does not own movement.",
        "STALE": "That command is out of date. Press again.",
        "LINK_DOWN": "The motor controller (ESP32) is not connected.",
        "NOT_READY": "The motor controller has not armed yet.",
        "FAULT": "A fault is latched. Clear it first.",
        "PLUG": "The charge plug is in.",
        "SHUTTING_DOWN": "The robot is shutting down.",
        "NETWORK_SHARED": "Driving is off on shared networks.",
        "TASK_ACTIVE": "A task is running. Cancel it first.",
        "NO_TASK": "No task is running.",
        "UNAVAILABLE": "Not available on this robot right now.",
        "CONFIRM_REQUIRED": "This needs a confirm.",
        "NO_FAULT": "There is no fault to clear.",
        "REARM_REFUSED": "The controller refused to clear the fault.",
        "MOVE_REFUSED": "The controller refused the move.",
        "INTERNAL": "Internal error.",
        "TIMEOUT": "The robot did not answer in time.",
        "OFFLINE": "Not connected to the robot.",
    ]
    public static func message(_ code: String?) -> String { code.flatMap { messages[$0] } ?? "Command refused." }
}

public struct RobotEvent: Equatable, Sendable {
    public var kind: String
    public var body: [String: JSONValue]
    public init(kind: String, body: [String: JSONValue] = [:]) { self.kind = kind; self.body = body }
}

public enum ServerMessage: Sendable {
    case hello(client: String, state: RobotState, capabilities: Capabilities)
    case state(RobotState)
    case event(RobotEvent)
    case ack(Ack)
    case unknown(String)

    private struct Envelope: Decodable { var type: String }
    private struct HelloMsg: Decodable { var client: String; var state: RobotState; var capabilities: Capabilities }
    private struct StateMsg: Decodable { var state: RobotState }
    private struct EventMsg: Decodable { var event: [String: JSONValue] }

    public static func decode(_ data: Data) throws -> ServerMessage {
        let d = DORMEJSON.decoder
        let type = try d.decode(Envelope.self, from: data).type
        switch type {
        case "hello":
            let m = try d.decode(HelloMsg.self, from: data)
            return .hello(client: m.client, state: m.state, capabilities: m.capabilities)
        case "state": return .state(try d.decode(StateMsg.self, from: data).state)
        case "event":
            let body = try d.decode(EventMsg.self, from: data).event
            return .event(RobotEvent(kind: body["kind"]?.string ?? "unknown", body: body))
        case "ack": return .ack(try d.decode(Ack.self, from: data))
        default: return .unknown(type)
        }
    }
}

// MARK: - Client protocol

public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case pairingRequired
    case connected
    case offline(String)        // was reachable, now is not (or never answered)
    case unavailable(String)    // configuration problem: bad address, wrong API version
}

public enum ClientEvent: Sendable {
    case phase(ConnectionPhase)
    case state(RobotState, receivedAt: Date)
    case capabilities(Capabilities)
    case event(RobotEvent)
    case tasks(TaskList)
}

/// One interface for the isolated demo and the real Wi-Fi robot. Everything the UI does goes
/// through it, so the demo can never reach a real robot and the real client never invents data.
@MainActor
public protocol RobotClient: AnyObject {
    var isDemo: Bool { get }
    var displayName: String { get }
    var onEvent: ((ClientEvent) -> Void)? { get set }
    func connect() async
    func disconnect() async
    func pair(pin: String) async -> Ack
    func send(_ command: RobotCommand) async -> Ack
    /// Stop uses the most direct path available and needs no pairing.
    func stop() async -> Ack
    func refreshTasks() async
}
