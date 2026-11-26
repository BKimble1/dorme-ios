import SwiftUI
import DORMEKit

/// Put DORM-E on Wi-Fi over Bluetooth (2026-11-26; pairing needs the code on its screen since v3). The phone pairs over Bluetooth first; that session's
/// key seals the Wi-Fi password before it leaves the phone (DORMEKit BLEPairing). DORM-E lists the networks it can
/// see, so the name does not have to be typed. If the new network fails, the robot goes back to the old one.
struct BluetoothSetupView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var robotID: UUID?
    @State private var pairing = false
    @State private var pairMessage: String?
    @State private var ssid = ""
    @State private var password = ""
    @State private var enterprise = false
    @State private var username = ""
    @State private var domain = ""
    @State private var hidden = false
    @State private var typing = false
    @State private var sent = false

    private var paired: Bool { robotID.map { store.ble.pairedOverBluetooth.contains($0) } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                if robotID == nil {
                    chooseRobot
                } else if !paired {
                    pairStep
                } else if sent {
                    Section { result }
                } else if ssid.isEmpty && !typing {
                    chooseNetwork
                } else {
                    credentials
                }
            }
            .navigationTitle("Wi-Fi setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                store.ble.start()
                if robotID == nil, store.ble.devices.count == 1 { robotID = store.ble.devices[0].id }
            }
            .onChange(of: store.ble.devices.count) { _, n in
                if robotID == nil, n == 1 { robotID = store.ble.devices[0].id }
            }
            .onChange(of: paired) { _, now in
                if now, let id = robotID { store.ble.scanNetworks(id) }
            }
            .onChange(of: robotID) { _, id in
                if let id, paired, store.ble.networks[id] == nil { store.ble.scanNetworks(id) }
            }
            .task {
                if let id = robotID, paired, store.ble.networks[id] == nil { store.ble.scanNetworks(id) }
            }
        }
    }

    @ViewBuilder private var chooseRobot: some View {
        Section {
            if store.ble.devices.isEmpty {
                HStack { ProgressView(); Text("Searching nearby (\(store.ble.radio))") }
            }
            ForEach(store.ble.devices) { d in
                Button { robotID = d.id } label: {
                    HStack {
                        Text(d.name)
                        Spacer()
                        Text(d.wifiName ?? "No Wi-Fi").foregroundStyle(.secondary)
                    }
                }
            }
        } header: { Text("Nearby") } footer: { Text("Keep the phone within a few metres of DORM-E.") }
    }

    @ViewBuilder private var pairStep: some View {
        Section {
            if let id = robotID { BluetoothPairCard(robotID: id) }
        } footer: {
            Text("Pairing needs the code DORM-E shows on its screen, so only someone who can see the robot can pair.")
        }
    }

    @ViewBuilder private var chooseNetwork: some View {
        let id = robotID
        let list = id.flatMap { store.ble.networks[$0] } ?? []
        Section {
            if list.isEmpty {
                HStack {
                    if id.map({ store.ble.scanning.contains($0) }) ?? false { ProgressView() }
                    Text(id.map({ store.ble.scanning.contains($0) }) ?? false ? "DORM-E is looking for networks" : "No networks yet")
                }
            }
            ForEach(list) { n in
                Button {
                    ssid = n.ssid
                    enterprise = n.security == "enterprise"
                } label: {
                    HStack {
                        Text(n.ssid)
                        Spacer()
                        if n.security != "open" { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                        if let s = n.signal { Text("\(s)%").foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
            }
            Button("Other network…") { typing = true }
            Button("Look again") { if let id { store.ble.scanNetworks(id) } }
        } header: { Text("Networks DORM-E can see") } footer: {
            Text("For remote access from anywhere, pick a network with internet. An iPhone hotspot works too: open Settings → Personal Hotspot on the phone while DORM-E joins.")
        }
    }

    @ViewBuilder private var credentials: some View {
        Section {
            TextField("Network name", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Needs a username (school or work)", isOn: $enterprise)
            if enterprise {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            SecureField("Password", text: $password)
            if enterprise {
                TextField("Server domain (e.g. school.edu)", text: $domain)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Toggle("Hidden network", isOn: $hidden)
        }
        Section {
            Button("Join") { send() }.disabled(ssid.isEmpty || (enterprise && username.isEmpty))
            Button("Back to the list") { ssid = ""; typing = false }
        }
    }

    @ViewBuilder private var result: some View {
        let r = robotID.flatMap { store.ble.results[$0] }
        switch r?.ok {
        case .some(true):
            Label("DORM-E joined \(r?.ssid ?? ssid)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            Button("Connect") {
                if let ip = r?.ipv4 { store.connect(host: ip, port: store.savedPort) } else { store.autoConnect() }
                dismiss()
            }
        case .some(false):
            Label(r?.message ?? "Could not join", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
            Button("Try again") {
                if let id = robotID { store.ble.clearResult(id) }
                sent = false
            }
        default:
            HStack { ProgressView(); Text(r?.message ?? "Joining") }
        }
    }

    private func send() {
        guard let id = robotID else { return }
        var creds: [String: Any] = ["ssid": ssid]
        if enterprise {
            var eap: [String: Any] = ["identity": username, "password": password]
            if !domain.isEmpty { eap["domain"] = domain }
            creds["eap"] = eap
        } else if !password.isEmpty {
            creds["psk"] = password
        }
        if hidden { creds["hidden"] = true }
        guard store.ble.sendWifi(id, credentials: creds) else { sent = true; return }
        password = ""
        sent = true
    }
}
