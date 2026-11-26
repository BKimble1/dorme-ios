import SwiftUI
import DORMEKit

/// Home: the live robot. Status, connection (inline, no sheet), the 3D model tinted by part health,
/// issues, three key readings and the camera. The search bar finds any part.
struct HomeView: View {
    @Environment(RobotStore.self) private var store
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showCover = true
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if query.isEmpty {
                        StatusHeader()
                        if !store.isDemo && store.phase != .connected { ConnectPanel() }
                        modelCard
                        if let issues = store.state?.health?.issues, !issues.isEmpty, store.phase == .connected || store.isDemo {
                            IssuesCard(issues: issues) { path.append($0) }
                        }
                        if store.state != nil { ReadingsRow() }
                        CameraPanel()
                    } else {
                        PartList(parts: PartCatalog.search(query)) { path.append($0) }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 110)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("DORM-E")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search parts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(for: String.self) { PartDetailView(partID: $0) }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    /// What the robot's screen shows right now (nil = dark: not connected).
    private var liveFace: String? {
        store.phase == .connected || store.isDemo ? store.state?.face.state : nil
    }

    private var statuses: [String: String] {
        guard let parts = store.state?.health?.parts, store.phase == .connected || store.isDemo else { return [:] }
        return Dictionary(parts.map { (PartKey.norm($0.key), $0.value.s) }, uniquingKeysWith: { a, _ in a })
    }

    private var modelCard: some View {
        ZStack(alignment: .bottomTrailing) {
            RobotSceneView(statuses: statuses, showCover: showCover, face: liveFace, note: store.state?.screen?.note,
                           faceDirection: store.state?.motion.direction,
                           onTap: { path.append($0) }, onCoverTap: { showCover = false })
                .frame(height: 340)
            Button { showCover.toggle() } label: {
                Image(systemName: showCover ? "cube.transparent.fill" : "cube.transparent")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(12)
            .accessibilityLabel(showCover ? "Hide cover" : "Show cover")
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// One line: overall state, colour coded.
struct StatusHeader: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        let (text, level) = summary
        HStack(spacing: 10) {
            Circle().fill(level.color).frame(width: 12, height: 12)
            Text(text).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            if store.isDemo { Pill(text: "Demo", symbol: "sparkles", level: .simulated, filled: true) }
            else if let s = store.state, s.robot.benchMode, store.phase == .connected { Pill(text: "Bench") }
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: (String, Level) {
        if store.isDemo || store.phase == .connected {
            if !store.freshness.isLive { return ("Not updating", .warn) }
            guard let h = store.state?.health else { return ("Connected", .good) }
            switch h.overall {
            case "ok": return ("Operational", .good)
            case "warn": return (h.headline, .warn)
            default: return (h.headline, .bad)
            }
        }
        switch store.phase {
        case .connecting: return ("Connecting", .neutral)
        case .pairingRequired: return ("Pair to continue", .warn)
        default: return (store.connectState == .searching ? "Looking for DORM-E" : "Offline", .neutral)
        }
    }
}

struct IssuesCard: View {
    var issues: [HealthIssue]
    var open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(issues) { issue in
                Button { open(PartCatalog.part(issue.id)?.id ?? issue.id) } label: {
                    HStack(spacing: 12) {
                        StatusDot(level: Level(partStatus: issue.status))
                        Text(PartCatalog.name(issue.id)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Text(issue.text).font(.subheadline).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if issue.id != issues.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 16)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}

/// Battery, Pi temperature, Wi-Fi signal.
struct ReadingsRow: View {
    @Environment(RobotStore.self) private var store

    var body: some View {
        let s = store.state
        HStack(spacing: 10) {
            Reading(symbol: "battery.75percent", value: s?.battery.voltageV.map { String(format: "%.1f V", $0) } ?? "–",
                    level: Level(partStatus: s?.health?.part("BATTERY")?.s))
            Reading(symbol: "cpu", value: s?.health?.part("PI4")?.t ?? "–", level: Level(partStatus: s?.health?.part("PI4")?.s))
            Reading(symbol: "wifi", value: s?.network.wifiDbm.map { "\($0) dBm" } ?? (s?.network.wifiSsid == nil ? "–" : "On"),
                    level: Level(partStatus: s?.health?.part("WIFI")?.s))
        }
        .staleness(store.dimmed)
    }
}

struct Reading: View {
    var symbol: String
    var value: String
    var level: Level

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(level == .neutral ? Theme.inkSecondary : level.color)
            Text(value).font(.headline).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
    }
}

/// Search results: every part, its live status, tap for detail.
struct PartList: View {
    var parts: [CatalogPart]
    var open: (String) -> Void
    @Environment(RobotStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ForEach(parts) { part in
                let h = store.state?.health?.part(part.id)
                Button { open(part.id) } label: {
                    HStack(spacing: 12) {
                        PartThumb(part: part)
                            .overlay(alignment: .bottomTrailing) {
                                StatusDot(level: Level(partStatus: h?.s)).padding(2)
                                    .background(Circle().fill(Color.white)).offset(x: 4, y: 4)
                            }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(part.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(part.category.capitalized).font(.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(h?.t ?? "").font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            if parts.isEmpty {
                Text("No matching part").foregroundStyle(Theme.inkSecondary).padding(.vertical, 24)
            }
        }
    }
}
