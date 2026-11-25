import SwiftUI
import DORMEKit

@MainActor
struct ConnectView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "8080"
    @State private var pin = ""
    @State private var codeShown = false
    @State private var pairing = false
    @State private var pairMessage: String?
    @State private var ble = BLEScanner()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    demoCard
                    robotCard
                    if store.network != nil && store.phase == .pairingRequired { pairCard }
                    nearbyCard
                    if store.hasClient {
                        Button(role: .destructive) { store.disconnect() } label: {
                            Label("Disconnect", systemImage: "xmark.circle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                host = store.savedHost
                port = String(store.savedPort)
                ble.start()
            }
            .onDisappear { ble.stopScanning() }
            .onChange(of: store.phase) { _, p in
                if p == .connected { dismiss() }
            }
        }
    }

    private var demoCard: some View {
        Card(fill: Theme.cardRaised) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Demo", systemImage: "theatermasks").font(.headline)
                Text("Works right away with no hardware. Everything is simulated and labelled, and it never connects to a robot.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                Button {
                    store.startDemo()
                } label: {
                    Text(store.isDemo ? "Restart demo" : "Start demo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.ink).controlSize(.large)
            }
        }
    }

    private var robotCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("DORM-E on Wi-Fi", systemImage: "wifi").font(.headline)
                TextField("Address, e.g. dorm-e.local", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Robot address")
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Port")
                Button {
                    store.connect(host: host, port: Int(port) ?? 8080)
                } label: {
                    Text("Connect").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.ink).controlSize(.large)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                phaseLine
                Text("Use the same Wi-Fi as the robot. Plain HTTP on your local network; driving stays off on networks marked shared.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    @ViewBuilder private var phaseLine: some View {
        if store.network != nil {
            switch store.phase {
            case .connecting: Label("Connecting…", systemImage: "arrow.triangle.2.circlepath").font(.footnote)
            case .connected: Label("Connected", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
            case .offline(let why): Label(why, systemImage: "wifi.slash").font(.footnote).foregroundStyle(Theme.bad)
            case .unavailable(let why): Label(why, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.bad)
            case .pairingRequired: Label("Robot found. Enter the code from its screen below.", systemImage: "key").font(.footnote)
            case .idle: EmptyView()
            }
        }
    }

    private var codeNote: String {
        if codeShown {
            return "DORM-E is showing a 6-digit code on its screen. Type it here within 2 minutes. It works once. (The PIN from the robot's label works too.)"
        }
        return "Asking DORM-E to show a code on its screen… If its screen is off, enter the PIN from the robot's label instead."
    }

    private func requestCode() async {
        let ack = await store.showPairingCode()
        codeShown = ack.ok
        pairMessage = ack.ok ? nil : ack.message
    }

    private var pairCard: some View {
        Card(fill: Theme.cardRaised) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pair", systemImage: "key.fill").font(.headline)
                Text(codeNote)
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                TextField("6-digit code", text: $pin)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .font(.system(.title2, design: .monospaced))
                    .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    pairing = true
                    Task {
                        let ack = await store.pair(pin: pin)
                        pairing = false
                        pin = ""
                        pairMessage = ack.ok ? nil : ack.message
                    }
                } label: {
                    HStack { if pairing { ProgressView() }; Text("Pair").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.ink)
                .disabled(pin.count < 6 || pairing)
                Button("Show the code on the robot again") { Task { await requestCode() } }
                    .font(.footnote)
                if let pairMessage { Label(pairMessage, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Theme.bad) }
            }
        }
        .task { if !codeShown { await requestCode() } }
    }

    private var nearbyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Nearby (Bluetooth)", systemImage: "dot.radiowaves.left.and.right").font(.headline)
                    Spacer()
                    Text(ble.radio).font(.caption).foregroundStyle(Theme.inkTertiary)
                }
                if ble.devices.isEmpty {
                    Text("No DORM-E advertising nearby. Bluetooth discovery needs the robot's BLE bridge running.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
                ForEach(ble.devices) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(d.name).font(.subheadline.weight(.semibold))
                            if d.simulated { Pill(text: "Simulated", level: .simulated) }
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundStyle(Theme.inkTertiary)
                        }
                        Text(bleSummary(d)).font(.footnote).foregroundStyle(Theme.inkSecondary)
                        HStack {
                            if let addr = d.addresses.first {
                                Button("Use \(addr)") {
                                    host = addr
                                    if let p = d.port { port = String(p) }
                                }
                                .buttonStyle(.bordered).tint(Theme.ink)
                            }
                            if d.canStop {
                                Button("Stop", role: .destructive) { ble.sendStop(d.id) }.buttonStyle(.borderedProminent).tint(Theme.stop)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let m = ble.lastMessage { Text(m).font(.footnote).foregroundStyle(Theme.inkSecondary) }
            }
        }
    }

    private func bleSummary(_ d: BLEScanner.Nearby) -> String {
        var parts: [String] = []
        if let v = d.voltage { parts.append(String(format: "%.2f V", v)) } else { parts.append("No voltage reading") }
        if let e = d.esp { parts.append("controller \(e)") }
        if let f = d.fault { parts.append("fault \(f)") }
        return parts.joined(separator: " · ")
    }
}

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
                        Text("These change the simulated robot only. Nothing here can reach real hardware.")
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
