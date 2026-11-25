import SwiftUI
import DORMEKit

struct ControlView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Screen(title: "Control") {
            CameraPanel(large: true)
                .frame(maxHeight: 460)
                .overlay(alignment: .bottomLeading) {
                    if let s = store.state {
                        Pill(text: StatusText.motion(s), symbol: s.motion.state == "moving" ? "location.north.fill" : "pause.fill")
                            .padding(12)
                    }
                }
            DriveStatusLine()
            DrivePad()
            SpeedCard()
            StopButton { store.stop() }
            Text("Hold an arrow to drive; lift your finger to stop. If the phone loses the robot, the robot stops by itself within half a second.")
                .font(.footnote).foregroundStyle(Theme.inkSecondary)
        }
    }
}

@MainActor
struct DriveStatusLine: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        let line = describe()
        HStack(spacing: 8) {
            StatusDot(level: line.1)
            Text(line.0).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func describe() -> (String, Level) {
        switch store.driveStatus {
        case .claiming(let d): return ("Asking to drive \(d.label.lowercased())…", .neutral)
        case .driving(let d):
            let bench = store.state?.motion.outputs == "disabled_bench"
            return (bench ? "Holding \(d.label.lowercased()) (bench: motors off)" : "Driving \(d.label.lowercased())", bench ? .neutral : .good)
        case .refused(_, let message): return (message, .warn)
        case .idle:
            guard let s = store.state else { return ("Waiting for the robot", .neutral) }
            if !store.freshness.isLive { return ("Driving is paused until the robot's data is fresh.", .warn) }
            if let block = s.motion.driveBlockMessage { return (block, .warn) }
            if s.motion.owner?.source == "task" { return ("A task is moving the robot.", .neutral) }
            return ("Ready to drive", .good)
        }
    }
}

@MainActor
struct DrivePad: View {
    @Environment(RobotStore.self) private var store

    private var enabled: Bool {
        guard let s = store.state, store.freshness.isLive else { return false }
        return s.motion.driveAllowed && s.power.shuttingDown == nil
    }

    var body: some View {
        let active = store.driveStatus
        Card(fill: Theme.card) {
            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    hold(.forward, active)
                    Color.clear.frame(width: 1, height: 1)
                }
                GridRow {
                    hold(.left, active)
                    Image(systemName: "figure.walk.motion").font(.title2).foregroundStyle(Theme.inkTertiary)
                        .accessibilityHidden(true)
                    hold(.right, active)
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    hold(.back, active)
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func hold(_ d: Direction, _ status: DriveSession.Status) -> some View {
        let isActive: Bool = {
            switch status {
            case .driving(let x), .claiming(let x): return x == d
            default: return false
            }
        }()
        return HoldButton(direction: d, enabled: enabled, active: isActive,
                          onPress: { store.press(d) }, onRelease: { store.release() })
    }
}

/// Press-and-hold control. @GestureState resets when the touch ends OR is cancelled (incoming
/// call, Control Center), so a lost touch always releases.
struct HoldButton: View {
    let direction: Direction
    let enabled: Bool
    let active: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @GestureState private var down = false

    var body: some View {
        Image(systemName: direction.symbol)
            .font(.system(size: 30, weight: .bold))
            .frame(width: 88, height: 88)
            .foregroundStyle(active ? Color.white : Theme.ink)
            .background(active ? Theme.ink : Color.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.hairline))
            .scaleEffect(down ? 0.95 : 1)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($down) { _, state, _ in state = true }
            )
            .onChange(of: down) { _, isDown in
                if isDown {
                    if enabled { onPress() }
                } else {
                    onRelease()
                }
            }
            .sensoryFeedback(.selection, trigger: down)
            .accessibilityElement()
            .accessibilityLabel("Drive \(direction.label.lowercased())")
            .accessibilityHint(enabled ? "Hold to drive. Release to stop." : "Driving is not available right now.")
            .accessibilityAddTraits(.isButton)
    }
}

struct SpeedCard: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        let levels = store.capabilities?.drive.speedLevelsPct ?? [30]
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Speed", symbol: "tortoise")
                HStack(spacing: 8) {
                    ForEach(levels, id: \.self) { pct in
                        Text("Slow · \(pct) % PWM")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Theme.ink, in: Capsule())
                    }
                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.inkTertiary)
                }
                Text(store.capabilities?.drive.speedNote ?? "Phone speed is fixed at the slow setting in V1.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
