import SwiftUI
import DORMEKit

struct HomeView: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        Screen(title: "DORM-E") {
            if let s = store.state {
                RobotCard(state: s)
                if let fault = s.fault.active { FaultCard(fault: fault) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 12)], spacing: 12) {
                    BatteryCard(battery: s.battery)
                    ControllerCard(state: s)
                }
                if let task = s.task, !task.state.isTerminal { CurrentTaskCard(task: task) }
                CameraPanel()
                QuickActions()
                NotMeasuredNote(items: s.notMeasured)
            } else {
                WaitingCard()
            }
        }
    }
}

struct WaitingCard: View {
    @Environment(RobotStore.self) private var store
    var body: some View {
        Card {
            HStack(spacing: 14) {
                ProgressView()
                Text(store.phase == .pairingRequired ? "Pair to see the robot's status." : "Waiting for the robot's first status…")
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        StopButton { store.stop() }
    }
}

struct RobotCard: View {
    var state: RobotState
    @Environment(RobotStore.self) private var store

    var body: some View {
        Card(padding: 14, fill: Theme.cardRaised) {
            VStack(alignment: .leading, spacing: 14) {
                FaceView(state: state.face.state, dimmed: store.dimmed)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.robot.name).font(.title2.weight(.bold))
                        Text(StatusText.motion(state)).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                            .staleness(store.dimmed)
                    }
                    Spacer()
                    let mode = StatusText.mode(state, demo: store.isDemo)
                    Pill(text: mode.0, level: mode.1)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

struct BatteryCard: View {
    var battery: Battery
    @Environment(RobotStore.self) private var store

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "Battery", symbol: battery.low == true ? "battery.25" : "battery.75",
                           trailing: battery.simulated ? "simulated" : nil)
                if let v = battery.voltageV {
                    Text(String(format: "%.2f V", v))
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .contentTransition(.numericText())
                        .foregroundStyle(battery.low == true ? Theme.bad : Theme.ink)
                    Text(battery.underLoad ? "At the logic rail · under load" : "At the logic rail")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("—").font(.system(.largeTitle, design: .rounded).weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                    Text(battery.voltageReason ?? "No reading").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                if battery.low == true {
                    Label(lowText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold)).foregroundStyle(Theme.bad)
                }
                Text("Percentage: not calibrated").font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
        .staleness(store.dimmed)
        .accessibilityElement(children: .combine)
    }

    private var lowText: String {
        guard let threshold = battery.lowThresholdV else { return "Low" }
        let basis = battery.lowBasis.map { ", \($0)" } ?? ""
        return String(format: "Low (below %.1f V", threshold) + basis + ")"
    }
}

struct ControllerCard: View {
    var state: RobotState
    @Environment(RobotStore.self) private var store

    var body: some View {
        let c = StatusText.controller(state)
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "Motor controller", symbol: "cpu")
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(level: c.1).padding(.top, 6)
                    Text(c.0).font(.headline).fixedSize(horizontal: false, vertical: true)
                }
                if let gap = state.connection.hbGapMaxMs {
                    Text("Longest heartbeat gap \(gap) ms").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                Text(state.motion.outputs == "disabled_bench" ? "Motor outputs off (bench)" : "Motor outputs enabled")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .staleness(store.dimmed)
        .accessibilityElement(children: .combine)
    }
}

struct FaultCard: View {
    var fault: FaultInfo
    @Environment(RobotStore.self) private var store
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill").font(.title2).foregroundStyle(Theme.bad)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fault.title).font(.headline)
                    Text(fault.code).font(.caption.monospaced()).foregroundStyle(Theme.inkSecondary)
                }
            }
            Text(fault.detail).font(.subheadline).foregroundStyle(Theme.ink)
            switch fault.rearm {
            case "phone_or_voice", "phone":
                Button("Clear fault…") { confirming = true }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                    .confirmationDialog("Clear \(fault.code)?", isPresented: $confirming, titleVisibility: .visible) {
                        Button("Clear fault") { store.rearm() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Clearing starts no motion. The robot checks the cause is gone first, and the next move still needs a new command.")
                    }
            case "auto":
                Text("Clears by itself when the cause goes away.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            default:
                Text("Needs service. Software cannot clear this.").font(.footnote.weight(.semibold)).foregroundStyle(Theme.bad)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bad.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

struct CurrentTaskCard: View {
    var task: RobotTask
    @Environment(RobotStore.self) private var store

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "Current task", symbol: "bolt.horizontal",
                           trailing: task.bench ? "bench rehearsal" : nil)
                Text(task.title).font(.headline)
                Text(task.step).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                ProgressCapsule(value: task.progress)
                Button(role: .destructive) { store.cancelTask() } label: {
                    Label("Cancel task", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
            }
        }
        .staleness(store.dimmed)
    }
}

@MainActor
struct QuickActions: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            StopButton { store.stop() }
            HStack(spacing: 12) {
                tile("Say hello", "hand.wave") { store.startTask("greet") }
                tile("Self check", "checklist") { store.startTask("self_check") }
                tile("Drive", "dpad") { store.tab = .control }
            }
        }
    }

    private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(Theme.ink)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(store.dimmed)
    }
}

struct NotMeasuredNote: View {
    var items: [String]
    var body: some View {
        let names = items.map { $0.replacingOccurrences(of: "_", with: " ") }
        Text("DORM-E has no sensor for \(ListFormatter.localizedString(byJoining: names)). The app never estimates them.")
            .font(.caption).foregroundStyle(Theme.inkTertiary)
            .padding(.horizontal, 4)
    }
}
