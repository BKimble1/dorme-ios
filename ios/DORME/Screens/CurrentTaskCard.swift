import SwiftUI
import DORMEKit

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
