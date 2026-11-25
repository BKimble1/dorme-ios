import SwiftUI
import DORMEKit

/// Plain-language status strings. The robot measures motion only as "commanded" (no encoders),
/// battery only as voltage (no percent), and nothing about current, runtime or temperature.
@MainActor
enum StatusText {
    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func connection(_ store: RobotStore) -> (String, Level) {
        switch store.phase {
        case .idle: return ("Not connected", .neutral)
        case .connecting: return ("Connecting", .neutral)
        case .pairingRequired: return ("Pair to continue", .warn)
        case .unavailable: return ("Unavailable", .bad)
        case .offline:
            if let at = store.lastMessageAt { return ("Offline · \(clock.string(from: at))", .bad) }
            return ("Offline", .bad)
        case .connected:
            switch store.freshness {
            case .waiting: return ("Waiting for data", .neutral)
            case .live: return (store.isDemo ? "Demo · live" : "Live", store.isDemo ? .simulated : .good)
            case .stale(let age): return ("Stale · \(Int(age)) s", .warn)
            case .offline(let at): return ("Offline · \(at.map { clock.string(from: $0) } ?? "never")", .bad)
            }
        }
    }

    static func motion(_ s: RobotState) -> String {
        if let reason = s.power.shuttingDown { return "Shutting down (\(reason))" }
        let sim = s.robot.simulated ? ", simulated" : ""
        if s.motion.state == "moving", let d = s.motion.direction.flatMap(Direction.init(rawValue:)) {
            return "Moving \(d.label.lowercased()) (commanded\(sim))"
        }
        if s.motion.owner != nil && s.motion.outputs == "disabled_bench" {
            return "Bench: drive request received, motors off"
        }
        if let task = s.task, task.state == .running { return "Running: \(task.title)" }
        return "Stopped"
    }

    static func controller(_ s: RobotState) -> (String, Level) {
        switch s.connection.esp32 {
        case "up":
            return ("Controller link up\(s.connection.espState.map { " · \($0)" } ?? "")", s.robot.simulated ? .simulated : .good)
        case "lost": return ("Controller link lost. Stop can't reach the wheels: use S2.", .bad)
        case "never": return ("No motor controller has answered yet.", .neutral)
        default: return ("Link service (dorme-linkd) is not running.", .warn)
        }
    }

    static func mode(_ s: RobotState, demo: Bool) -> (String, Level) {
        if demo { return ("Demo", .simulated) }
        if s.robot.simulated { return ("Simulator", .simulated) }
        return ("Hardware", .good)
    }
}

/// Every tab: big title, connection pill, banners, then content. Leaves room for the tab bar.
struct Screen<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(RobotStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.largeTitle.weight(.bold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button { store.showConnect = true } label: {
                        let c = StatusText.connection(store)
                        Pill(text: c.0, level: c.1)
                    }
                    .accessibilityLabel("Connection: \(StatusText.connection(store).0). Opens connection settings.")
                }
                Banners()
                if store.hasClient {
                    content
                } else {
                    NotConnectedCard()
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 12)
            .padding(.bottom, 110)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }
}

struct NotConnectedCard: View {
    @Environment(RobotStore.self) private var store
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.largeTitle).foregroundStyle(Theme.inkSecondary)
                Text("Not connected").font(.title2.weight(.bold))
                Text("Try the demo, which needs no hardware, or connect to DORM-E on your Wi-Fi.")
                    .foregroundStyle(Theme.inkSecondary)
                HStack {
                    Button("Start demo") { store.startDemo() }.buttonStyle(.borderedProminent).tint(Theme.ink)
                    Button("Connect…") { store.showConnect = true }.buttonStyle(.bordered).tint(Theme.ink)
                }
            }
        }
    }
}

struct Banner: View {
    var symbol: String
    var text: String
    var level: Level
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.headline).foregroundStyle(level.color).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(Theme.ink).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline.weight(.semibold)).tint(Theme.ink)
            }
        }
        .padding(14)
        .background(level.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Connecting, offline, unavailable, stale, fault-adjacent and mode banners, most urgent first.
@MainActor
struct Banners: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            if store.isDemo {
                Banner(symbol: "theatermasks", text: "Demo mode. All data is simulated; no robot is connected.",
                       level: .simulated, actionTitle: "Scenarios") { store.showDemoControls = true }
            }
            switch store.phase {
            case .connecting:
                Banner(symbol: "arrow.triangle.2.circlepath", text: "Connecting to \(store.client?.displayName ?? "robot")…", level: .neutral)
            case .pairingRequired:
                Banner(symbol: "key", text: "Enter the robot's PIN to see status and drive. Stop works without it.",
                       level: .warn, actionTitle: "Pair") { store.showConnect = true }
            case .offline(let why):
                Banner(symbol: "wifi.slash", text: offlineText(why), level: .bad, actionTitle: "Retry") {
                    if let c = store.client { Task { await c.connect() } }
                }
            case .unavailable(let why):
                Banner(symbol: "exclamationmark.triangle", text: why, level: .bad, actionTitle: "Change") { store.showConnect = true }
            default:
                EmptyView()
            }
            if store.phase == .connected {
                switch store.freshness {
                case .stale(let age):
                    Banner(symbol: "clock.badge.exclamationmark", text: "No update for \(Int(age)) s. Values are greyed and may be out of date.", level: .warn)
                case .offline(let at):
                    Banner(symbol: "wifi.slash", text: "Offline. Last seen \(at.map { StatusText.clock.string(from: $0) } ?? "never").", level: .bad)
                default:
                    EmptyView()
                }
            }
            if let s = store.state {
                if s.robot.simulated && !store.isDemo {
                    Banner(symbol: "desktopcomputer", text: "Simulator. The coordinator is running with a simulated ESP32; nothing here is a real reading.", level: .simulated)
                }
                if s.connection.esp32 == "lost" {
                    Banner(symbol: "bolt.horizontal.circle", text: "Controller link lost. Stop cannot reach the wheels: use the S2 switch.", level: .bad)
                }
                if let reason = s.power.shuttingDown {
                    Banner(symbol: "power", text: reason == "PLUG" ? "Charge plug detected, shutting down." : "Shutting down (\(reason)).", level: .warn)
                }
                if s.robot.benchMode {
                    Banner(symbol: "wrench.and.screwdriver", text: "Bench mode. Motor outputs are off; drive commands are rehearsed only.", level: .neutral)
                }
                if s.fault.lastOffForced {
                    Banner(symbol: "exclamationmark.octagon", text: "Last power-off was forced.", level: .warn)
                }
            }
        }
    }

    private func offlineText(_ why: String) -> String {
        if let at = store.lastMessageAt { return "\(why) Last seen \(StatusText.clock.string(from: at))." }
        return why
    }
}

struct CapsuleTabBar: View {
    @Binding var selection: RobotStore.Tab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(RobotStore.Tab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 17, weight: .semibold))
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(selected ? Color.white : Theme.inkSecondary)
                    .background(selected ? Theme.ink : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(6)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 6)
        .padding(.horizontal, 24)
        .frame(maxWidth: 460)
        .animation(.spring(duration: 0.25), value: selection)
    }
}
