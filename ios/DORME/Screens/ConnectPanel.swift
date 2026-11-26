import SwiftUI
import DORMEKit

/// Connection, inline on the home page. Finds the robot by itself; shows only what is needed next.
struct ConnectPanel: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var showAddress = false
    @State private var showBluetooth = false

    var body: some View {
        Card(fill: Theme.cardRaised) {
            VStack(alignment: .leading, spacing: 14) {
                if store.phase == .pairingRequired {
                    PairPanel()
                } else if store.connectState == .searching || store.phase == .connecting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(store.phase == .connecting ? "Connecting" : "Looking for DORM-E").font(.headline)
                        Spacer()
                    }
                } else {
                    notFound
                }
            }
        }
        .task { if !store.hasClient && store.connectState == .idle { store.autoConnect() } }
        .sheet(isPresented: $showBluetooth) { BluetoothSetupView() }
    }

    @ViewBuilder private var notFound: some View {
        if store.discovery.denied {
            Label("Allow Local Network for DORM-E", systemImage: "lock.shield").font(.headline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent).tint(Theme.ink)
        } else {
            Text(offlineText).font(.headline)
        }
        HStack(spacing: 10) {
            Button { store.autoConnect() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderedProminent).tint(Theme.ink)
            if !store.ble.devices.isEmpty {
                Button { showBluetooth = true } label: { Label("Set up Wi-Fi", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.bordered).tint(Theme.ink)
            }
            Menu {
                Button("Enter address") { showAddress.toggle() }
                Button("Set up Wi-Fi over Bluetooth") { showBluetooth = true }
                Button("Try the demo") { store.startDemo() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .tint(Theme.ink)
            .accessibilityLabel("More")
        }
        if showAddress {
            HStack {
                TextField("dorm-e.local", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("connect.address")
                    .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Go") { store.connect(host: address, port: store.savedPort) }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onAppear { address = store.savedHost }
        }
    }

    private var offlineText: String {
        if case .offline(let why) = store.phase { return why }
        if case .unavailable(let why) = store.phase { return why }
        return store.ble.devices.isEmpty ? "DORM-E not found" : "DORM-E is nearby, not on Wi-Fi"
    }
}

/// Pairing: DORM-E shows a code and QR on its screen. Scan the QR or type the 6 digits.
struct PairPanel: View {
    @Environment(RobotStore.self) private var store
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter the code on DORM-E's screen").font(.headline)
            HStack(spacing: 10) {
                TextField("000000", text: $code)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .accessibilityIdentifier("pair.code")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onChange(of: code) { _, new in
                        code = String(new.filter(\.isNumber).prefix(6))
                        if code.count == 6 { submit(code) }
                    }
                Button { scanning = true } label: { Image(systemName: "qrcode.viewfinder").font(.title2) }
                    .buttonStyle(.bordered).tint(Theme.ink)
                    .accessibilityLabel("Scan the code")
            }
            HStack {
                if busy { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.bad) }
                Spacer()
                Button("New code") { Task { _ = await store.showPairingCode() } }.font(.footnote)
            }
        }
        .task { _ = await store.showPairingCode() }
        .sheet(isPresented: $scanning) {
            QRScannerView { text in
                scanning = false
                if let qr = PairingQR(text) {
                    busy = true
                    Task {
                        let ack = await store.pair(qr: qr)
                        busy = false
                        message = ack.ok ? nil : ack.message
                    }
                }
            }
            .ignoresSafeArea()
        }
    }

    private func submit(_ value: String) {
        guard !busy else { return }
        busy = true
        Task {
            let ack = await store.pair(pin: value)
            busy = false
            message = ack.ok ? nil : ack.message
            if !ack.ok { code = "" }
        }
    }
}
