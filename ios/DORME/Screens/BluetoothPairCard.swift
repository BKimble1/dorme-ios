import SwiftUI

/// Pairing over Bluetooth with the code on DORM-E's screen (v3, 2026-11-26). Tap Pair: the robot shows a
/// six-digit code. Type it here: the phone proves it saw the code (the code itself is never sent), the robot
/// pairs this phone and takes the code off its screen.
struct BluetoothPairCard: View {
    let robotID: UUID
    var onPaired: () -> Void = {}
    @Environment(RobotStore.self) private var store
    @State private var askingCode = false
    @State private var code = ""
    @State private var busy = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if askingCode {
                Text("Enter the code on DORM-E's screen").font(.headline)
                HStack(spacing: 10) {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .accessibilityIdentifier("ble.code")
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .focused($focused)
                        .onChange(of: code) { _, new in
                            code = String(new.filter(\.isNumber).prefix(6))
                            if code.count == 6 { finish() }
                        }
                    if busy { ProgressView() }
                }
                HStack {
                    if let message { Text(message).font(.footnote).foregroundStyle(Theme.bad) }
                    Spacer()
                    Button("New code") { start() }.font(.footnote).disabled(busy)
                }
            } else {
                HStack {
                    Button { start() } label: {
                        Label("Pair over Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.ink).disabled(busy)
                    if busy { ProgressView() }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(Theme.bad) }
                Text("DORM-E will show a code on its screen.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func start() {
        busy = true
        message = nil
        code = ""
        Task {
            let why = await store.startBluetoothPairing(robotID)
            busy = false
            if let why {
                message = why
            } else {
                askingCode = true
                focused = true
            }
        }
    }

    private func finish() {
        guard !busy else { return }
        busy = true
        message = nil
        let typed = code
        Task {
            let why = await store.finishBluetoothPairing(robotID, code: typed)
            busy = false
            if let why {
                message = why
                code = ""
                if why == "Start pairing again." || why.contains("expired") || why.contains("Wait") { askingCode = false }
            } else {
                onPaired()
            }
        }
    }
}
