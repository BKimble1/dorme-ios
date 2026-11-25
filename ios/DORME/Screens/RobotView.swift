import SwiftUI
import DORMEKit

/// One physical part of DORM-E. Parts come from output/reports/SHOPPING_LIST_FINAL.md and the
/// software spec. `verified` states what has actually been checked on hardware, nothing more.
struct RobotComponent: Identifiable {
    let id: String
    let name: String
    let part: String
    let role: String
    let symbol: String
    let spot: CGPoint            // position on the silhouette, 0...1
    let verified: String
    let status: (RobotState?) -> (String, Level)

    @MainActor static let all: [RobotComponent] = [
        RobotComponent(id: "face", name: "Face display", part: "SuziePi 3.5 in, 480 x 320 SPI (ILI9486)",
                       role: "Shows the face. Status lives on the phone, not the screen.", symbol: "face.smiling",
                       spot: CGPoint(x: 0.5, y: 0.26),
                       verified: "Face boots on the Pi and shows on the panel (owner-confirmed 2026-11-09). Touch unused.") { s in
            guard let s else { return ("No data", .neutral) }
            let ok = ["ok", "simulated"].contains(s.face.adapter)
            return ("\(FaceView.describe(s.face.state)) · \(ok ? "app link to face OK" : s.face.adapterReason ?? s.face.adapter)", ok ? .good : .warn)
        },
        RobotComponent(id: "camera", name: "Camera", part: "OV5647 (U12), turned 90° in A03: portrait picture",
                       role: "Live view on Control. Which way is up is not verified yet.", symbol: "camera",
                       spot: CGPoint(x: 0.5, y: 0.10),
                       verified: "Not yet run on DORM-E. Orientation and fit are open.") { s in
            RobotComponent.peripheral(s?.peripherals.camera)
        },
        RobotComponent(id: "pi", name: "Raspberry Pi 4B", part: "Pi 4 Model B Rev 1.5, 1 GB",
                       role: "Coordinator: face, camera, audio, tasks and the phone connection.", symbol: "cpu",
                       spot: CGPoint(x: 0.36, y: 0.44),
                       verified: "Boots and runs the face. The coordinator in this app's repo has not been installed on it yet.") { s in
            guard let s else { return ("No data", .neutral) }
            return ("Coordinator \(s.robot.software) · \(s.robot.mode)", s.robot.simulated ? .simulated : .good)
        },
        RobotComponent(id: "esp32", name: "Motor controller", part: "ESP32 DevKitC (esp32dev target)",
                       role: "Owns PWM, sensors, interlocks and the 300 ms command expiry.", symbol: "memorychip",
                       spot: CGPoint(x: 0.64, y: 0.44),
                       verified: "Firmware compiled and host-tested; never flashed. Pins must be checked on the board's silkscreen.") { s in
            guard let s else { return ("No data", .neutral) }
            return StatusText.controller(s)
        },
        RobotComponent(id: "battery", name: "Battery", part: "Tenergy 9.6 V NiMH pack",
                       role: "Measured as voltage only, at the logic rail.", symbol: "battery.75",
                       spot: CGPoint(x: 0.5, y: 0.62),
                       verified: "No discharge log yet, so no percentage or warning band.") { s in
            guard let v = s?.battery.voltageV else { return (s?.battery.voltageReason ?? "No reading", .neutral) }
            return (String(format: "%.2f V%@", v, s?.battery.simulated == true ? " (simulated)" : ""), s?.battery.low == true ? .bad : .good)
        },
        RobotComponent(id: "ina219", name: "Voltage sensor", part: "INA219 (U9), bus voltage only",
                       role: "Feeds the battery reading and low-voltage stop.", symbol: "gauge.with.needle",
                       spot: CGPoint(x: 0.3, y: 0.62),
                       verified: "Not yet wired or read.") { s in
            s?.battery.voltageV != nil ? ("Reading", .good) : ("No reading", .neutral)
        },
        RobotComponent(id: "sonar", name: "Sonar", part: "HC-SR04 through SN74AHCT125 (U10)",
                       role: "Forward obstacle refuse (30 cm) and stop (20 cm), in firmware.", symbol: "dot.radiowaves.right",
                       spot: CGPoint(x: 0.5, y: 0.78),
                       verified: "Not yet wired or read.") { s in
            guard let p = s?.peripherals.sonar else { return ("No data", .neutral) }
            if let cm = p.distanceCm { return ("\(cm) cm\(p.status == "simulated" ? " (simulated)" : "")", p.status == "simulated" ? .simulated : .good) }
            return (p.reason ?? "Unavailable", .neutral)
        },
        RobotComponent(id: "motors_left", name: "Left drive", part: "2 x Adafruit 5857 1:90 TT on one MD20A",
                       role: "Moves only on a fresh command. Motion shown is commanded, not measured.", symbol: "gearshape.2",
                       spot: CGPoint(x: 0.12, y: 0.82),
                       verified: "Motors not yet run. No torque, speed or turning capability is claimed.") { s in
            RobotComponent.motion(s)
        },
        RobotComponent(id: "motors_right", name: "Right drive", part: "2 x Adafruit 5857 1:90 TT on one MD20A",
                       role: "Moves only on a fresh command. Motion shown is commanded, not measured.", symbol: "gearshape.2",
                       spot: CGPoint(x: 0.88, y: 0.82),
                       verified: "Motors not yet run. No torque, speed or turning capability is claimed.") { s in
            RobotComponent.motion(s)
        },
        RobotComponent(id: "audio", name: "Audio", part: "Waveshare USB audio (U16) + 8 Ω speaker",
                       role: "Microphones and chimes.", symbol: "speaker.wave.2",
                       spot: CGPoint(x: 0.8, y: 0.3),
                       verified: "Card detection only. Playback is not connected to the coordinator yet.") { s in
            RobotComponent.peripheral(s?.peripherals.audio)
        },
        RobotComponent(id: "ble", name: "Bluetooth", part: "Pi 4B onboard radio",
                       role: "Nearby discovery, setup info, status and Stop. Never driving.", symbol: "dot.radiowaves.left.and.right",
                       spot: CGPoint(x: 0.2, y: 0.3),
                       verified: "BLE bridge written, not yet run on the Pi.") { s in
            RobotComponent.peripheral(s?.peripherals.ble)
        },
        RobotComponent(id: "s2", name: "Power button S2", part: "Wrexon 16 mm latching button",
                       role: "The hardware off switch. Cuts motor power with no software.", symbol: "power",
                       spot: CGPoint(x: 0.5, y: 0.46),
                       verified: "Not yet wired. The app cannot press it: use it whenever Stop cannot reach the wheels.") { s in
            if let r = s?.power.shuttingDown { return ("Shutting down (\(r))", .warn) }
            return ("Not readable by the app", .neutral)
        },
    ]

    static func peripheral(_ p: Peripheral?) -> (String, Level) {
        guard let p else { return ("No data", .neutral) }
        switch p.status {
        case "available", "detected", "advertising": return (p.status.capitalized, .good)
        case "simulated": return ("Simulated", .simulated)
        default: return (p.reason ?? p.status.replacingOccurrences(of: "_", with: " ").capitalized, .neutral)
        }
    }

    static func motion(_ s: RobotState?) -> (String, Level) {
        guard let s else { return ("No data", .neutral) }
        if s.motion.outputs == "disabled_bench" { return ("Outputs off (bench)", .neutral) }
        return (s.motion.state == "moving" ? "Moving (commanded)" : "Stopped", s.motion.state == "moving" ? .good : .neutral)
    }
}

struct RobotView: View {
    @Environment(RobotStore.self) private var store
    @State private var selected: RobotComponent?

    var body: some View {
        Screen(title: "Robot") {
            RobotSilhouette(state: store.state) { selected = $0 }
            SectionTitle(text: "Components")
            Card(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(RobotComponent.all) { c in
                        let st = c.status(store.state)
                        Button { selected = c } label: {
                            HStack(spacing: 12) {
                                Image(systemName: c.symbol).font(.body.weight(.semibold)).frame(width: 30).foregroundStyle(Theme.ink)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text(st.0).font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                                }
                                Spacer()
                                StatusDot(level: st.1)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkTertiary)
                            }
                            .padding(.vertical, 11).padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("Shows details")
                        if c.id != RobotComponent.all.last?.id { Divider().padding(.leading, 52) }
                    }
                }
            }
            .staleness(store.dimmed)
        }
        .sheet(item: $selected) { c in ComponentSheet(component: c).presentationDetents([.medium, .large]) }
    }
}

/// An original, simple silhouette of DORM-E Concept B (rounded cover, head screen, four wheels).
struct RobotSilhouette: View {
    var state: RobotState?
    var onSelect: (RobotComponent) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // wheels
                ForEach([0.12, 0.88], id: \.self) { x in
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ink.opacity(0.85))
                        .frame(width: w * 0.14, height: h * 0.24)
                        .position(x: w * x, y: h * 0.8)
                }
                // body / cover
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous).fill(Theme.cardRaised)
                    .overlay(RoundedRectangle(cornerRadius: w * 0.16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 2))
                    .frame(width: w * 0.72, height: h * 0.62)
                    .position(x: w * 0.5, y: h * 0.6)
                // head
                RoundedRectangle(cornerRadius: w * 0.07, style: .continuous).fill(Theme.cardRaised)
                    .overlay(RoundedRectangle(cornerRadius: w * 0.07, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 2))
                    .frame(width: w * 0.5, height: h * 0.32)
                    .position(x: w * 0.5, y: h * 0.24)
                FaceView(state: state?.face.state ?? "idle")
                    .frame(width: w * 0.4)
                    .position(x: w * 0.5, y: h * 0.25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                // hotspots
                ForEach(RobotComponent.all) { c in
                    let level = c.status(state).1
                    Button { onSelect(c) } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 30, height: 30)
                                .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                            Circle().fill(level.color).frame(width: 12, height: 12)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .position(x: w * c.spot.x, y: h * c.spot.y)
                    .accessibilityLabel(c.name)
                    .accessibilityValue(c.status(state).0)
                    .accessibilityHint("Shows details")
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

struct ComponentSheet: View {
    var component: RobotComponent
    @Environment(RobotStore.self) private var store

    var body: some View {
        let st = component.status(store.state)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        StatusDot(level: st.1)
                        Text(st.0).font(.headline)
                    }
                    if store.dimmed { Label("Out of date: the robot's data is stale or offline.", systemImage: "clock") }
                } header: { Text("Now") }
                Section("What it does") { Text(component.role) }
                Section("Part") { Text(component.part) }
                Section("Verified on hardware") { Text(component.verified) }
            }
            .navigationTitle(component.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
