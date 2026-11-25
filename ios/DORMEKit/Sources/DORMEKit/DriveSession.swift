import Foundation

/// Hold-to-drive. While a direction is held the session sends drive.hold every `intervalMs` with
/// an increasing sequence number. Releasing (or any refusal, stop, disconnect or app backgrounding)
/// ends the loop at once; the robot's lease then stops the wheels even if the release message is
/// lost. Nothing here retries a refused hold: the user has to press again.
@MainActor
public final class DriveSession {
    public enum Status: Equatable, Sendable {
        case idle
        case claiming(Direction)
        case driving(Direction)
        case refused(code: String, message: String)
    }

    public private(set) var status: Status = .idle {
        didSet { if oldValue != status { onChange?(status) } }
    }
    public var onChange: ((Status) -> Void)?
    public private(set) var holdsSent = 0

    private let send: (RobotCommand) async -> Ack
    private var intervalMs: Int
    private var claim: String?
    private var seq = 0
    private var pressed: Direction?
    private var loop: Task<Void, Never>?

    public init(intervalMs: Int = 200, send: @escaping (RobotCommand) async -> Ack) {
        self.intervalMs = intervalMs
        self.send = send
    }

    public func setInterval(ms: Int) { intervalMs = max(100, min(ms, 300)) }

    public var activeDirection: Direction? {
        if case .driving(let d) = status { return d }
        return nil
    }

    public func press(_ direction: Direction) {
        pressed = direction
        loop?.cancel()
        loop = Task { [weak self] in await self?.run(direction) }
    }

    /// Finger lifted: stop sending holds and tell the robot. The lease is the backstop.
    public func release() {
        pressed = nil
        loop?.cancel()
        loop = nil
        if let token = claim {
            let send = self.send
            Task { _ = await send(.release(claim: token)) }
        }
        claim = nil
        if case .refused = status { return }
        status = .idle
    }

    /// Stop pressed, socket lost or app backgrounded: forget everything without sending.
    public func reset() {
        pressed = nil
        loop?.cancel()
        loop = nil
        claim = nil
        status = .idle
    }

    public func clearRefusal() {
        if case .refused = status { status = .idle }
    }

    private func refuse(_ ack: Ack) {
        pressed = nil
        claim = nil
        loop?.cancel()
        status = .refused(code: ack.code ?? "REFUSED", message: ack.message)
    }

    private func run(_ direction: Direction) async {
        if claim == nil {
            status = .claiming(direction)
            let ack = await send(.claim())
            guard !Task.isCancelled, pressed == direction else {
                if ack.ok, let token = ack.result.lookup("claim")?.string {
                    _ = await send(.release(claim: token))      // released while claiming
                }
                return
            }
            guard ack.ok, let token = ack.result.lookup("claim")?.string else {
                refuse(ack)
                return
            }
            claim = token
            seq = 0
        }
        status = .driving(direction)
        while !Task.isCancelled, pressed == direction, let token = claim {
            seq += 1
            holdsSent += 1
            let command = RobotCommand.hold(claim: token, direction: direction, seq: seq)
            // Do not wait for the ack before the next tick: a slow round trip must not let the
            // lease lapse mid-press. Acks are checked as they arrive.
            Task { [weak self] in
                let ack = await self?.send(command)
                guard let self, let ack, !ack.ok, self.pressed == direction else { return }
                self.refuse(ack)
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }
}
