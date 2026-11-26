import SwiftUI
import DORMEKit

@MainActor
struct TasksView: View {
    @Environment(RobotStore.self) private var store
    @State private var detail: RobotTask?

    private var catalog: [TaskCatalogEntry] { store.tasks?.catalog ?? store.capabilities?.tasks ?? [] }
    private var running: RobotTask? {
        guard let t = store.state?.task, !t.state.isTerminal else { return nil }
        return t
    }

    var body: some View {
        Screen(title: "Tasks") {
            if let task = running {
                CurrentTaskCard(task: task)
            }
            SectionTitle(text: "Screen")
            ScreenNoteCard()
            SectionTitle(text: "Actions")
            if catalog.isEmpty {
                Card { Text("No actions yet. The list appears once the robot answers.").foregroundStyle(Theme.inkSecondary) }
            }
            ForEach(catalog) { entry in
                TaskRow(entry: entry, busy: running != nil) { store.startTask(entry.action) }
            }
            SectionTitle(text: "Recent")
            let history = store.tasks?.history ?? []
            if history.isEmpty {
                Text("Nothing has run yet.").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            } else {
                Card(padding: 6) {
                    VStack(spacing: 0) {
                        ForEach(history) { task in
                            Button { detail = task } label: { HistoryRow(task: task) }
                                .buttonStyle(.plain)
                            if task.id != history.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                }
            }
        }
        .sheet(item: $detail) { task in TaskDetailSheet(task: task).presentationDetents([.medium, .large]) }
        .task { await store.client?.refreshTasks() }
    }
}

struct TaskRow: View {
    var entry: TaskCatalogEntry
    var busy: Bool
    var run: () -> Void
    @Environment(RobotStore.self) private var store

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: entry.symbol)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(entry.available ? Theme.ink : Theme.inkTertiary)
                    .background(Color.white, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.title).font(.headline)
                        if entry.usesMotion {
                            Text("Moves").font(.caption2.weight(.bold)).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.accent.opacity(0.18), in: Capsule())
                        }
                    }
                    Text(entry.detail).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !entry.available, let reason = entry.unavailableReason ?? entry.unavailableCode.map({ AckCode.message($0) }) {
                        Label(reason, systemImage: "nosign").font(.footnote).foregroundStyle(Theme.warn)
                    }
                }
                Spacer(minLength: 0)
                Button("Run", action: run)
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                    .disabled(!entry.available || busy || store.dimmed)
                    .accessibilityLabel("Run \(entry.title)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct HistoryRow: View {
    var task: RobotTask

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(task.error?.message ?? task.summary ?? task.state.rawValue.capitalized)
                    .font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
            Spacer()
            if let ended = task.endedAt {
                Text(Date(timeIntervalSince1970: ended), style: .relative).font(.caption).foregroundStyle(Theme.inkTertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkTertiary)
        }
        .padding(.vertical, 12).padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch task.state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "clock"
        }
    }

    private var color: Color {
        switch task.state {
        case .succeeded: return Theme.good
        case .failed: return Theme.bad
        default: return Theme.inkTertiary
        }
    }
}

struct TaskDetailSheet: View {
    var task: RobotTask

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Result", value: task.state.rawValue.capitalized)
                    if let s = task.summary { Text(s) }
                    if let n = task.note { Label(n, systemImage: "info.circle").foregroundStyle(Theme.inkSecondary) }
                    if let e = task.error { Label("\(e.message) (\(e.code))", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.bad) }
                    if task.bench { Label("Bench rehearsal: no motor output was sent.", systemImage: "wrench.and.screwdriver") }
                }
                if !task.checks.isEmpty {
                    Section("Checks") {
                        ForEach(task.checks) { c in
                            HStack(alignment: .top) {
                                StatusDot(level: c.status == "ok" ? .good : c.status == "warn" ? .warn : .neutral).padding(.top, 6)
                                VStack(alignment: .leading) {
                                    Text(c.name).font(.subheadline.weight(.semibold))
                                    Text(c.detail).font(.footnote).foregroundStyle(Theme.inkSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
