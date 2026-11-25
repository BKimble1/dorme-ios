import Foundation

// Swift mirror of spec/schema/api_v1.schema.json (API v1). Decode with `DORMEJSON.decoder`
// (snake_case -> camelCase). Every measurement the robot cannot make is Optional and is shown as
// unavailable, never filled in.

public enum DORMEJSON {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

// MARK: - Free-form JSON

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Looks a key up as written in the spec (snake_case) and as the decoder may have converted it.
    public subscript(key: String) -> JSONValue? { object?.lookup(key) }
}

public extension Dictionary where Key == String, Value == JSONValue {
    func lookup(_ key: String) -> JSONValue? { self[key] ?? self[DORMEKeys.camel(key)] }
}

public enum DORMEKeys {
    public static func camel(_ snake: String) -> String {
        let parts = snake.split(separator: "_")
        guard let first = parts.first else { return snake }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

// MARK: - Robot state

public struct RobotState: Codable, Equatable, Sendable {
    public var seq: Int
    public var robot: RobotInfo
    public var connection: ConnectionInfo
    public var battery: Battery
    public var motion: Motion
    public var task: RobotTask?
    public var fault: FaultBlock
    public var power: Power
    public var face: FaceInfo
    public var peripherals: Peripherals
    public var network: NetworkInfo
    public var notMeasured: [String]
}

public struct RobotInfo: Codable, Equatable, Sendable {
    public var name: String
    public var mode: String            // "hardware", "simulator"; the app's own demo uses "demo"
    public var simulated: Bool
    public var software: String
    public var api: Int
    public var benchMode: Bool
    public var backend: String?
}

public struct ConnectionInfo: Codable, Equatable, Sendable {
    public var esp32: String           // up, lost, never, linkd_down
    public var espState: String?
    public var statAgeMs: Int?
    public var hbGapMaxMs: Int?
    public var linkdDryRun: Bool?
    public var firmware: String?
    public var resetReason: String?
}

public struct Battery: Codable, Equatable, Sendable {
    public var voltageV: Double?
    public var voltageReason: String?
    public var basis: String?
    public var ageMs: Int?
    public var underLoad: Bool
    public var percent: Double?        // always nil until calibration exists
    public var percentReason: String
    public var low: Bool?
    public var lowThresholdV: Double?
    public var lowBasis: String?
    public var simulated: Bool
}

public struct MotionOwner: Codable, Equatable, Sendable {
    public var source: String
    public var client: String
    public var direction: String?
}

public struct LastStop: Codable, Equatable, Sendable {
    public var at: Double
    public var source: String
    public var reachedController: Bool
}

public struct Motion: Codable, Equatable, Sendable {
    public var state: String           // stopped, moving, stopping
    public var direction: String?      // F B L R
    public var basis: String           // always "commanded": no encoders
    public var owner: MotionOwner?
    public var outputs: String         // enabled, disabled_bench
    public var driveAllowed: Bool
    public var driveBlock: String?
    public var driveBlockMessage: String?
    public var lastStop: LastStop?
}

public enum TaskState: String, Codable, Sendable {
    case pending, running, succeeded, failed, cancelled, unknown
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TaskState(rawValue: raw) ?? .unknown
    }
    public var isTerminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}

public struct TaskSource: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
}

public struct TaskError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
}

public struct RobotTask: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var action: String
    public var title: String
    public var state: TaskState
    public var progress: Double?
    public var step: String
    public var source: TaskSource?
    public var usesMotion: Bool
    public var bench: Bool
    public var createdAt: Double?
    public var endedAt: Double?
    public var elapsedMs: Int?
    public var result: [String: JSONValue]
    public var error: TaskError?

    public var summary: String? { result.lookup("summary")?.string }
    public var note: String? { result.lookup("note")?.string }
    public var checks: [SelfCheckItem] {
        (result.lookup("checks")?.array ?? []).compactMap { v in
            guard let name = v["name"]?.string, let status = v["status"]?.string else { return nil }
            return SelfCheckItem(name: name, status: status, detail: v["detail"]?.string ?? "")
        }
    }
}

public struct SelfCheckItem: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var status: String          // ok, warn, unavailable
    public var detail: String
}

public struct FaultInfo: Codable, Equatable, Sendable {
    public var code: String
    public var title: String
    public var detail: String
    public var rearm: String           // phone_or_voice, phone, service, auto
    public var phoneCanClear: Bool { rearm == "phone_or_voice" || rearm == "phone" }
}

public struct FaultBlock: Codable, Equatable, Sendable {
    public var active: FaultInfo?
    public var lastOffForced: Bool
}

public struct Power: Codable, Equatable, Sendable {
    public var plug: Bool?
    public var shuttingDown: String?
    public var motorRailOn: Bool?
    public var motorRailV: Double?
}

public struct FaceInfo: Codable, Equatable, Sendable {
    public var state: String
    public var adapter: String
    public var adapterReason: String?
}

public struct Peripheral: Codable, Equatable, Sendable {
    public var status: String
    public var reason: String?
    public var distanceCm: Int?
    public var streamPath: String?
    public var orientation: String?
    public var rotationDeg: Int?
    public var rotationVerified: Bool?
    public var playback: String?
    public var card: String?
    public var sensor: String?

    public init(status: String, reason: String? = nil, distanceCm: Int? = nil, streamPath: String? = nil) {
        self.status = status; self.reason = reason; self.distanceCm = distanceCm; self.streamPath = streamPath
    }

    /// Real hardware answered, or a clearly labelled simulation is standing in.
    public var isUsable: Bool { ["available", "detected", "advertising", "simulated"].contains(status) }
}

public struct Peripherals: Codable, Equatable, Sendable {
    public var camera: Peripheral
    public var audio: Peripheral
    public var ble: Peripheral
    public var sonar: Peripheral
}

public struct NetworkInfo: Codable, Equatable, Sendable {
    public var trust: String
}

// MARK: - Capabilities

public struct Capabilities: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var commands: [String]
    public var drive: DriveCaps
    public var tasks: [TaskCatalogEntry]
    public var battery: BatteryCaps
    public var camera: CameraCaps
    public var ble: [String: String]?
    public var staleness: Staleness
    public var notMeasured: [String]
}

public struct DriveCaps: Codable, Equatable, Sendable {
    public var directions: [String]
    public var holdToDrive: Bool?
    public var speedLevelsPct: [Int]
    public var turnSpeedPct: Int?
    public var speedNote: String?
    public var holdLeaseMs: Int
    public var holdIntervalMs: Int
}

public struct TaskCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { action }
    public var action: String
    public var title: String
    public var detail: String
    public var symbol: String
    public var usesMotion: Bool
    public var available: Bool
    public var unavailableCode: String?
    public var unavailableReason: String?
}

public struct BatteryCaps: Codable, Equatable, Sendable {
    public var voltage: Bool
    public var percent: Bool
    public var basis: String?
}

public struct CameraCaps: Codable, Equatable, Sendable {
    public var streamPath: String?
    public var snapshotPath: String?
    public var orientation: String?
    public var rotationDeg: Int?
    public var rotationVerified: Bool?
}

public struct Staleness: Codable, Equatable, Sendable {
    public var staleAfterMs: Int
    public var offlineAfterMs: Int
}

public struct TaskList: Codable, Equatable, Sendable {
    public var catalog: [TaskCatalogEntry]
    public var current: RobotTask?
    public var history: [RobotTask]
}
