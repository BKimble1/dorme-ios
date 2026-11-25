import SwiftUI
import DORMEKit

/// Everything that is not driving: where the robot is, its Wi-Fi, remote access, pairing, restarts, demo.
struct SettingsView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showBluetooth = false
    @State private var confirm: String?
    @State private var note: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Robot") {
                    LabeledContent("Address", value: store.network?.displayName ?? (store.isDemo ? "Demo" : "Not connected"))
                    if let s = store.state, !store.isDemo {
                        LabeledContent("Software", value: s.robot.software)
                        if let fw = s.connection.firmware { LabeledContent("Controller", value: fw) }
                    }
                    if store.hasClient {
                        Button("Disconnect", role: .destructive) { store.disconnect() }
                    } else {
                        Button("Find DORM-E") { store.autoConnect(); dismiss() }
                    }
                }

                Section("Wi-Fi") {
                    if let n = store.state?.network, store.phase == .connected {
                        LabeledContent("Network", value: n.wifiSsid ?? "Not connected")
                        NavigationLink("Networks") { WifiNetworksView() }
                    }
                    Button("Set up over Bluetooth") { showBluetooth = true }
                }

                Section("Remote access") {
                    let remote = store.state?.network.remote
                    LabeledContent("Status", value: remote?.online == true ? (remote?.name ?? "On") : "Off")
                    if store.phase == .connected && remote?.online != true {
                        Button("Turn on") {
                            Task {
                                let ack = await store.enableRemote()
                                if let url = ack.result.lookup("login_url")?.string, let u = URL(string: url) { openURL(u) }
                                else { note = ack.ok ? "Remote access is on." : ack.message }
                            }
                        }
                    }
                }

                if store.phase == .connected {
                    Section("Pairing") {
                        Button("Show code on DORM-E") { Task { _ = await store.showPairingCode() } }
                    }
                    Section("System") {
                        Button("Restart robot software") { Task { note = (await store.restartService("dorme-coordinator")).ok ? "Restarting" : "Refused" } }
                        Button("Restart motor link") { Task { note = (await store.restartService("dorme-linkd")).ok ? "Restarting" : "Refused" } }
                        Button("Reboot") { confirm = "reboot" }
                        Button("Power off", role: .destructive) { confirm = "poweroff" }
                    }
                }

                Section("Demo") {
                    if store.isDemo {
                        Button("Scenarios") { store.showDemoControls = true; dismiss() }
                        Button("Exit demo") { store.disconnect(); dismiss() }
                    } else {
                        Button("Try the demo") { store.startDemo(); dismiss() }
                    }
                }
                if let note { Section { Text(note).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showBluetooth) { BluetoothSetupView() }
            .confirmationDialog(confirm == "reboot" ? "Reboot DORM-E?" : "Power off DORM-E?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                titleVisibility: .visible) {
                Button(confirm == "reboot" ? "Reboot" : "Power off", role: .destructive) {
                    let action = confirm ?? "reboot"
                    Task { note = (await store.power(action)).ok ? "Done" : "Refused" }
                }
            }
        }
    }
}

/// The robot's Wi-Fi: current, saved and visible networks; add one with or without switching to it.
struct WifiNetworksView: View {
    @Environment(RobotStore.self) private var store
    @State private var status: WifiStatus?
    @State private var visible: [VisibleNetwork] = []
    @State private var scanning = false
    @State private var adding: String?

    var body: some View {
        List {
            if let saved = status?.saved, !saved.isEmpty {
                Section("Saved") {
                    ForEach(saved) { n in
                        HStack {
                            Text(n.ssid)
                            Spacer()
                            if n.ssid == status?.ssid { Image(systemName: "checkmark").foregroundStyle(Theme.good) }
                        }
                        .swipeActions {
                            if n.ssid != status?.ssid {
                                Button("Forget", role: .destructive) {
                                    Task { _ = await store.forgetWifi(n.ssid); await load() }
                                }
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(visible) { n in
                    Button { adding = n.ssid } label: {
                        HStack {
                            Text(n.ssid).foregroundStyle(Theme.ink)
                            Spacer()
                            if n.security != "open" { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                            Image(systemName: n.signal > 66 ? "wifi" : (n.signal > 33 ? "wifi" : "wifi.exclamationmark"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Other network") { adding = "" }
            } header: {
                HStack { Text("Nearby"); if scanning { ProgressView().controlSize(.small) } }
            }
        }
        .navigationTitle("Networks")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: Binding(get: { adding.map(AddingNetwork.init) }, set: { adding = $0?.ssid })) { item in
            AddNetworkSheet(ssid: item.ssid,
                            enterprise: visible.first { $0.ssid == item.ssid }?.security == "enterprise") { await load() }
        }
    }

    private func load() async {
        status = await store.wifiStatus()
        scanning = true
        visible = await store.wifiScan()
        scanning = false
    }
}

private struct AddingNetwork: Identifiable {
    let ssid: String
    var id: String { ssid }
}

struct AddNetworkSheet: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var ssid: String
    @State var enterprise: Bool
    var done: () async -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var joinNow = true
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Network name", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Needs a username", isOn: $enterprise)
                if enterprise {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                SecureField("Password", text: $password)
                if enterprise {
                    TextField("Server domain (e.g. school.edu)", text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Toggle("Switch to it now", isOn: $joinNow)
                if let message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("Add network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let ack = await store.addWifi(ssid: ssid, password: password, username: enterprise ? username : nil,
                                                          domain: enterprise ? domain : nil, joinNow: joinNow)
                            password = ""
                            if ack.ok {
                                await done()
                                dismiss()
                            } else {
                                message = ack.message
                            }
                        }
                    }
                    .disabled(ssid.isEmpty)
                }
            }
        }
    }
}
