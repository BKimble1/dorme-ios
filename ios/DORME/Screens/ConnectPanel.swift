import SwiftUI
import DORMEKit

/// Connection, inline on the home page. Finds the robot by itself; shows only what is needed next.
/// 2026-11-26: pairing is over Bluetooth with no code (the code and QR stay as a fallback), and when the robot is
/// paired but not on this phone's network the panel offers Wi-Fi setup over Bluetooth and the robot's own Wi-Fi.
struct ConnectPanel: View {
    @Environment(RobotStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var address = ""
    @State private var showAddress = false
    @State private var showBluetooth = false
    @State private var pairing = false
    @State private var pairMessage: String?

    var body: some View {
        Card(fill: Theme.cardRaised) {
            VStack(alignment: .leading, spacing: 14) {
                if store.phase == .pairingRequired {
                    PairPanel()
                } else if pairing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Pairing over Bluetooth").font(.headline)
                        Spacer()
                    }
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

    private var nearby: BLEScanner.Nearby? { store.ble.devices.first { $0.canPair } ?? store.ble.devices.first }

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
        if let pairMessage {
            Text(pairMessage).font(.footnote).foregroundStyle(Theme.bad)
        }
        HStack(spacing: 10) {
            if let robot = nearby, robot.canPair {
                if store.ble.pairedOverBluetooth.contains(robot.id) {
                    Button { showBluetooth = true } label: { Label("Put on Wi-Fi", systemImage: "wifi") }
                        .buttonStyle(.borderedProminent).tint(Theme.ink)
                } else {
                    Button { pair(robot.id) } label: {
                        Label("Connect with Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
                }
                Button { store.autoConnect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).tint(Theme.ink)
                    .accessibilityLabel("Retry")
            } else {
                Button { store.autoConnect() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).tint(Theme.ink)
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
        if let hot = store.hotspot {
            HotspotHint(ssid: hot.ssid, password: hot.password)
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

    private func pair(_ id: UUID) {
        pairing = true
        pairMessage = nil
        Task {
            pairMessage = await store.pairOverBluetooth(id)
            pairing = false
        }
    }

    private var offlineText: String {
        if case .offline(let why) = store.phase { return why }
        if case .unavailable(let why) = store.phase { return why }
        guard let robot = nearby else { return "DORM-E not found" }
        if store.ble.pairedOverBluetooth.contains(robot.id) {
            return robot.wifiName.map { "DORM-E is on \($0), not this network" } ?? "DORM-E is nearby, not on Wi-Fi"
        }
        return "DORM-E is nearby"
    }
}

/// Where there is no Wi-Fi at all, DORM-E makes its own after two minutes. Join it in iPhone Settings, then Retry.
struct HotspotHint: View {
    let ssid: String
    let password: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No Wi-Fi here? Join DORM-E's own Wi-Fi in Settings, then Retry.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(ssid).font(.footnote.weight(.semibold))
                Text(password).font(.footnote.monospaced())
                Button(copied ? "Copied" : "Copy password") {
                    UIPasteboard.general.string = password
                    copied = true
                }
                .font(.footnote)
            }
        }
    }
}

/// Pairing: over Bluetooth when DORM-E is nearby (no code); otherwise the code on DORM-E's screen or the label PIN.
struct PairPanel: View {
    @Environment(RobotStore.self) private var store
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @State private var scanning = false
    @State private var useCode = false

    private var nearby: BLEScanner.Nearby? { store.ble.devices.first { $0.canPair } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let robot = nearby, !useCode {
                Text("Pair with DORM-E").font(.headline)
                HStack {
                    Button {
                        busy = true
                        message = nil
                        Task {
                            message = await store.pairOverBluetooth(robot.id)
                            busy = false
                        }
                    } label: { Label("Pair over Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.borderedProminent).tint(Theme.ink).disabled(busy)
                    if busy { ProgressView() }
                    Spacer()
                    Button("Use a code") { useCode = true }.font(.footnote)
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.bad) }
            } else {
                codeEntry
            }
        }
        .onAppear { store.ble.start() }
    }

    @ViewBuilder private var codeEntry: some View {
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
