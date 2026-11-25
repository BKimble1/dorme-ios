import SwiftUI
import DORMEKit

struct DemoControlsView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // DemoRobot is not observable itself; reading the state's sequence number re-renders the
        // toggles whenever the demo emits a new state.
        let _ = store.state?.seq
        NavigationStack {
            List {
                if let demo = store.demo {
                    Section {
                        Toggle("Low battery", isOn: Binding(get: { demo.lowBattery }, set: { demo.setLowBattery($0) }))
                        Toggle("Camera available", isOn: Binding(get: { demo.cameraAvailable }, set: { demo.setCameraAvailable($0) }))
                        Toggle("Bench mode (motors off)", isOn: Binding(get: { demo.benchMode }, set: { demo.setBenchMode($0) }))
                        Toggle("Motor controller linked", isOn: Binding(get: { demo.controllerLinked }, set: { demo.setControllerLinked($0) }))
                    } header: { Text("Robot") } footer: {
                        Text("Simulated robot only.")
                    }
                    Section("Events") {
                        Button("Drop Wi-Fi for 14 s") { demo.simulateDisconnect(seconds: 14); dismiss() }
                        Button("Raise a clearable fault (STALE)") { demo.injectFault("STALE"); dismiss() }
                        Button("Raise a service fault (RAIL_LIVE)") { demo.injectFault("RAIL_LIVE"); dismiss() }
                        Button("Run self check") { store.startTask("self_check"); dismiss() }
                    }
                } else {
                    Text("Scenarios are only available in Demo mode.")
                }
            }
            .navigationTitle("Demo scenarios")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
