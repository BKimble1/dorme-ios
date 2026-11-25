import Foundation

/// Staleness rules from the spec (section 8, AUTH values): ages are measured on the phone from
/// when a message was received, because the Pi has no battery clock.
public enum Freshness: Equatable, Sendable {
    case waiting                    // connected, nothing received yet
    case live
    case stale(age: TimeInterval)   // values greyed and marked stale
    case offline(lastSeen: Date?)   // "Offline, last seen HH:MM:SS"

    public var isLive: Bool { self == .live }
}

public struct FreshnessPolicy: Sendable, Equatable {
    public var staleAfter: TimeInterval
    public var offlineAfter: TimeInterval

    public init(staleAfter: TimeInterval = 3, offlineAfter: TimeInterval = 10) {
        self.staleAfter = staleAfter
        self.offlineAfter = offlineAfter
    }

    public init(_ s: Staleness) {
        self.init(staleAfter: Double(s.staleAfterMs) / 1000, offlineAfter: Double(s.offlineAfterMs) / 1000)
    }

    public func evaluate(lastMessage: Date?, now: Date, socketOpen: Bool = true) -> Freshness {
        guard let last = lastMessage else { return socketOpen ? .waiting : .offline(lastSeen: nil) }
        let age = now.timeIntervalSince(last)
        if !socketOpen || age >= offlineAfter { return .offline(lastSeen: last) }
        if age >= staleAfter { return .stale(age: age) }
        return .live
    }
}
