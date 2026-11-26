import SwiftUI
import DORMEKit

/// Put DORM-E on Wi-Fi over Bluetooth. The robot shows a QR; scanning it gives the key that seals the
/// Wi-Fi password before it leaves the phone (DORMEKit/Pairing.swift).
struct BluetoothSetupView: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var robotID: UUID?
    @State private var qr: PairingQR?
    @State private var scanning = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var enterprise = false
    @State private var username = ""
    @State private var domain = ""
    @State private var sent = false

    var body: some View {
        NavigationStack {
            Form {
                if robotID == nil {
                    Section {
                        if store.ble.devices.isEmpty {
                            HStack { ProgressView(); Text("Searching nearby") }
                        }
                        ForEach(store.ble.devices) { d in
                            Button {
                                robotID = d.id
                                store.ble.requestCode(d.id)
                            } label: {
                                HStack {
                                    Text(d.name)
                                    Spacer()
                                    Text(d.wifiName ?? "No Wi-Fi").foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!d.canSetUpWifi)
                        }
                    } header: { Text("Nearby") }
                } else if qr == nil {
                    Section {
                        Button { scanning = true } label: { Label("Scan the code on DORM-E", systemImage: "qrcode.viewfinder") }
                        Button("Show the code again") { if let id = robotID { store.ble.requestCode(id) } }
                    }
                } else if !sent {
                    Section {
                        TextField("Network name", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Needs a username", isOn: $enterprise)
                        if enterprise {
                            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        SecureField("Password", text: $password)
                        if enterprise {
                            TextField("Server domain (e.g. school.edu)", text: $domain)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    Section {
                        Button("Join") { send() }.disabled(ssid.isEmpty || (enterprise && username.isEmpty))
                    }
                } else {
                    Section { result }
                }
            }
            .navigationTitle("Wi-Fi setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { store.ble.start() }
            .sheet(isPresented: $scanning) {
                QRScannerView { text in
                    scanning = false
                    if let parsed = PairingQR(text) {
                        qr = parsed
                        store.rememberQR(parsed)
                    }
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var result: some View {
        let r = robotID.flatMap { store.ble.results[$0] }
        switch r?.ok {
        case .some(true):
            Label("DORM-E joined \(r?.ssid ?? ssid)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
            if let ip = r?.ipv4 {
                Button("Connect") {
                    store.connect(host: ip, port: store.savedPort)
                    dismiss()
                }
            }
        case .some(false):
            Label(r?.message ?? "Could not join", systemImage: "xmark.circle.fill").foregroundStyle(Theme.bad)
            Button("Try again") {
                // a used or expired code can't seal again: show a new one and scan it
                if let id = robotID { store.ble.clearResult(id); store.ble.requestCode(id) }
                qr = nil
                sent = false
            }
        default:
            HStack { ProgressView(); Text(r?.message ?? "Joining") }
        }
    }

    private func send() {
        guard let qr, let id = robotID else { return }
        var creds: [String: Any] = ["ssid": ssid]
        if enterprise {
            var eap: [String: Any] = ["identity": username, "password": password]
            if !domain.isEmpty { eap["domain"] = domain }
            creds["eap"] = eap
        } else if !password.isEmpty {
            creds["psk"] = password
        }
        guard let sealed = try? WifiSeal.seal(creds, for: qr), store.ble.sendWifi(id, sealed: sealed) else { return }
        password = ""
        sent = true
    }
}
