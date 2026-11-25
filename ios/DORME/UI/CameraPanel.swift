import SwiftUI
import DORMEKit

/// Camera view. Real robot: MJPEG from the coordinator. Demo: a synthetic, labelled picture.
/// Unavailable: says why. The OV5647 is mounted portrait and which way is up is not verified yet,
/// so frames are rotated only when the robot reports a rotation, and a badge says so otherwise.
@MainActor
struct CameraPanel: View {
    var large = false
    @Environment(RobotStore.self) private var store
    @State private var stream = MJPEGStream()

    private var camera: Peripheral? { store.state?.peripherals.camera }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Color.black.opacity(0.88))
            content
        }
        .aspectRatio(large ? 3.0 / 4.0 : 4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .topLeading) { badges.padding(12) }
        .staleness(store.dimmed)
        .onAppear(perform: startIfNeeded)
        .onDisappear { stream.stop() }
        .onChange(of: camera?.status) { _, _ in startIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera")
    }

    @ViewBuilder private var content: some View {
        if let cam = camera, cam.isUsable {
            if store.isDemo {
                DemoCameraPicture()
            } else if let img = stream.image {
                Image(uiImage: img).resizable().scaledToFill()
                    .rotationEffect(.degrees(Double(cam.rotationDeg ?? 0)))
            } else if case .failed(let why) = stream.status {
                unavailable(why)
            } else {
                ProgressView().tint(.white)
            }
        } else {
            unavailable(camera?.reason ?? (store.state == nil ? "No data from the robot yet." : "Camera unavailable."))
        }
    }

    private func unavailable(_ reason: String) -> some View {
        // Black, as a camera with no picture looks. The reason is for VoiceOver only.
        Image(systemName: "video.slash").font(.title2).foregroundStyle(.white.opacity(0.35))
            .accessibilityLabel("No camera. \(reason)")
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if let cam = camera, cam.status == "simulated" || store.isDemo {
                Pill(text: "Simulated", symbol: "sparkles", level: .simulated, filled: true)
            }
            if let cam = camera, cam.isUsable, cam.rotationVerified != true, !store.isDemo {
                Pill(text: "Orientation unverified", symbol: "rotate.right")
            }
        }
    }

    private func startIfNeeded() {
        guard !store.isDemo, let cam = camera, cam.isUsable, let path = cam.streamPath,
              let client = store.network, stream.status == .idle else { return }
        stream.start(client.cameraRequest(path: String(path.drop(while: { $0 == "/" }))))
    }
}

/// Demo stand-in picture: a soft room scene with a moving ball. Obviously not a real image.
struct DemoCameraPicture: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [Color(red: 0.93, green: 0.90, blue: 0.85), Color(red: 0.80, green: 0.74, blue: 0.66)],
                                   startPoint: .top, endPoint: .bottom)
                    Rectangle().fill(Color(red: 0.62, green: 0.52, blue: 0.42))
                        .frame(height: geo.size.height * 0.35)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Circle().fill(Theme.accent)
                        .frame(width: geo.size.width * 0.16)
                        .position(x: geo.size.width * (0.5 + 0.3 * sin(t * 0.9)), y: geo.size.height * 0.72)
                    Text("DEMO CAMERA · NOT A REAL IMAGE")
                        .font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                }
            }
        }
        .accessibilityLabel("Simulated camera picture")
    }
}
