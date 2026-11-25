import SwiftUI
import DORMEKit

/// One part: where it is on the model, its live status, and every value the robot senses for it.
struct PartDetailView: View {
    let partID: String
    @Environment(RobotStore.self) private var store

    private var part: CatalogPart? { PartCatalog.part(partID) }
    private var health: PartHealth? { store.state?.health?.part(partID) }
    private var detail: PartDetail? {
        let key = PartKey.norm(partID)
        return store.system?.parts.first { PartKey.norm($0.id) == key }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if part?.node != nil {
                    RobotSceneView(statuses: [:], selected: partID)
                        .frame(height: 240)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                HStack(spacing: 10) {
                    Circle().fill(Level(partStatus: health?.s).color).frame(width: 12, height: 12)
                    Text(health?.t ?? (store.state == nil ? "Not connected" : "No live data"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                }
                .staleness(store.dimmed)
                if let values = detail?.values, !values.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(values.keys.sorted(), id: \.self) { key in
                            let row = ValueFormat.row(key, values[key] ?? .null)
                            HStack {
                                Text(row.0).foregroundStyle(Theme.inkSecondary)
                                Spacer()
                                Text(row.1).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
                    .staleness(store.dimmed)
                } else if health?.s == "none" {
                    Text("No sensor on this part.").foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 110)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(part?.name ?? partID)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await store.refreshSystem()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
