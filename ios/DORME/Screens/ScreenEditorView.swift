import PencilKit
import SwiftUI
import DORMEKit

/// DORM-E's screen editor (2026-11-26). One screen, top to bottom, the way the Apple Watch face editor and the iOS
/// Lock Screen do it: a Face | Custom switch, a live 3:2 preview that is exactly what the LCD will show (and in Custom
/// mode is also the canvas), one row of choices, one colour row, and one action.
///   Face:   style thumbnails, eye colour  -> "Use this face" (also the startup face)
///   Custom: Draw (pen, eraser, undo, clear) or Text (type, font, drag to move), colour, Blink, Show for /
///           Show at startup -> "Show on DORM-E"
/// Blinking is 1 flash a second (photosensitivity limit is 3). The robot keeps the saved choice across power cycles.
struct ScreenEditorView: View {
    @Environment(RobotStore.self) private var store
    @State private var mode: Mode = .face
    @State private var tool: Tool = .draw
    @State private var eraser = false
    @State private var style = "classic"
    @State private var eyeColor = RGB.swatches[0]
    @State private var penColor = RGB(255, 255, 255)
    @State private var canvasSize = CGSize(width: 480, height: 320)
    @State private var busy = false
    @State private var message: String?
    @State private var loadedFace = false
    @FocusState private var typing: Bool
    private let design = ScreenDesign.shared

    enum Mode: String, CaseIterable, Identifiable { case face = "Face", custom = "Custom"; var id: String { rawValue } }
    enum Tool: String, CaseIterable, Identifiable { case draw = "Draw", text = "Text"; var id: String { rawValue } }

    private static let durations: [(String, Int)] = [("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600),
                                                     ("30 minutes", 1800), ("1 hour", 3600), ("Until changed", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("screen.mode")

            preview
            if mode == .face { faceControls } else { customControls }
            nowShowing
            if let message {
                Text(message).font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            primaryButton
        }
        .onAppear(perform: loadFace)
        .onChange(of: store.state?.screen?.face) { _, _ in loadFace() }
    }

    // MARK: Preview (and canvas)

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                if mode == .face {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                        FacePreview(style: style, color: eyeColor, date: ctx.date)
                    }
                } else {
                    Color.black
                    TimelineView(.animation(minimumInterval: 1 / 10, paused: design.blink == .none)) { ctx in
                        let on = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) < 0.65
                        ZStack {
                            CanvasView(design: design, color: penColor, eraser: eraser, active: tool == .draw)
                                .opacity(design.blink == .drawing || design.blink == .all ? (on ? 1 : 0.15) : 1)
                            TextOverlay(design: design, size: geo.size)
                                .opacity(design.blink == .text || design.blink == .all ? (on ? 1 : 0.15) : 1)
                                .allowsHitTesting(tool == .text)
                        }
                    }
                }
            }
            .onAppear { canvasSize = geo.size }
            .onChange(of: geo.size) { _, s in canvasSize = s }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.black.opacity(0.85), lineWidth: 6))
        .accessibilityIdentifier("screen.preview")
        .accessibilityLabel(mode == .face ? "Preview of DORM-E's face" : "DORM-E's screen. Draw here.")
    }

    // MARK: Face

    private var faceControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(FaceRenderer.styles, id: \.id) { s in
                        Button { style = s.id } label: {
                            VStack(spacing: 6) {
                                Image(uiImage: StyleThumb.image(s.id, eyeColor))
                                    .resizable().aspectRatio(1.5, contentMode: .fit).frame(width: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(style == s.id ? Theme.accent : .clear, lineWidth: 2.5))
                                Text(s.name).font(.caption.weight(style == s.id ? .semibold : .regular))
                                    .foregroundStyle(style == s.id ? Theme.ink : Theme.inkSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("screen.style.\(s.id)")
                    }
                }
                .padding(.vertical, 2)
            }
            SwatchRow(selected: $eyeColor)
        }
    }

    // MARK: Custom

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
                Spacer()
                if tool == .draw {
                    IconToggle(symbol: "pencil.tip", on: !eraser, label: "Pen") { eraser = false }
                    IconToggle(symbol: "eraser", on: eraser, label: "Eraser") { eraser = true }
                    IconToggle(symbol: "arrow.uturn.backward", on: false, label: "Undo") { undo() }
                    IconToggle(symbol: "trash", on: false, label: "Clear drawing") { design.replaceDrawing(PKDrawing()) }
                }
            }
            if tool == .text {
                @Bindable var d = design
                TextField("Type a message", text: $d.text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($typing)
                    .submitLabel(.done)
                    .padding(12)
                    .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("screen.text")
                    .onChange(of: design.text) { _, new in if new.count > 80 { design.text = String(new.prefix(80)) } }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScreenDesign.Font.allCases) { f in
                            Button { design.font = f } label: {
                                Text("Aa").font(Font(f.uiFont(20) as CTFont))
                                    .frame(width: 58, height: 42)
                                    .background(design.font == f ? Theme.ink : Theme.cardRaised,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(design.font == f ? Theme.background : Theme.ink)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(f.name) font")
                        }
                    }
                }
                if !design.text.isEmpty {
                    Text("Drag the text on the screen to move it.").font(.caption).foregroundStyle(Theme.inkTertiary)
                }
            }
            SwatchRow(selected: tool == .text ? Binding(get: { design.textColor }, set: { design.textColor = $0 }) : $penColor)
            VStack(spacing: 0) {
                @Bindable var d = design
                HStack {
                    Text("Blink")
                    Spacer()
                    Picker("Blink", selection: $d.blink) {
                        ForEach(ScreenDesign.Blink.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu).tint(Theme.inkSecondary)
                }
                .padding(.vertical, 6)
                Divider()
                Toggle("Show at startup", isOn: $d.startup)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("screen.startup")
                if !design.startup {
                    Divider()
                    HStack {
                        Text("Show for")
                        Spacer()
                        Picker("Show for", selection: $d.seconds) {
                            ForEach(Self.durations, id: \.1) { Text($0.0).tag($0.1) }
                        }
                        .pickerStyle(.menu).tint(Theme.inkSecondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .background(Theme.cardRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if design.startup {
                Text("DORM-E shows this whenever it is resting, and right after it powers on. The face still appears while it drives or talks.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: What the robot shows now, and the action

    @ViewBuilder private var nowShowing: some View {
        let screen = store.state?.screen
        if let c = screen?.custom {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Theme.inkSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Showing \u{201C}\(c.label ?? "your screen")\u{201D}").font(.subheadline.weight(.semibold))
                    if let until = c.until {
                        Text(timerInterval: Date()...max(Date(), Date(timeIntervalSince1970: until)), countsDown: true)
                            .font(.caption.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer()
                Button("Face") { clear(startup: false) }.font(.subheadline.weight(.semibold))
            }
        } else if let r = screen?.resting {
            HStack(spacing: 8) {
                Image(systemName: "power").foregroundStyle(Theme.inkSecondary)
                Text("Resting screen: \u{201C}\(r.label ?? "your screen")\u{201D}").font(.subheadline).lineLimit(1)
                Spacer()
                Button("Use face") { clear(startup: true) }.font(.subheadline.weight(.semibold))
            }
        }
    }

    private var primaryButton: some View {
        Button {
            mode == .face ? applyFace() : showCustom()
        } label: {
            HStack {
                if busy { ProgressView().tint(Theme.background) }
                Text(mode == .face ? "Use this face" : "Show on DORM-E").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .disabled(busy || store.client == nil || (mode == .custom && design.isEmpty))
        .accessibilityIdentifier("screen.apply")
    }

    // MARK: Actions

    private func loadFace() {
        guard let face = store.state?.screen?.face, !loadedFace else { return }
        do {
            style = face.style
            if let c = RGB(face.color) { eyeColor = c }
            loadedFace = true
        }
    }

    private func undo() {
        guard !design.drawing.strokes.isEmpty else { return }
        var d = design.drawing
        d.strokes.removeLast()
        design.replaceDrawing(d)
    }

    private func applyFace() {
        busy = true
        message = nil
        Task {
            guard let client = store.client else { busy = false; return }
            var ack = await client.send(.screenFace(style: style, color: eyeColor == RGB.swatches[0] ? nil : eyeColor.list))
            if ack.ok, store.state?.screen?.resting != nil || store.state?.screen?.custom != nil {
                ack = await client.send(.screenClear(startup: true))
                if ack.ok { design.forgetResting() }
            }
            busy = false
            message = ack.ok ? "DORM-E is using this face, now and after it restarts." : ack.message
        }
    }

    private func showCustom() {
        typing = false
        busy = true
        message = nil
        Task {
            let why = await design.send(store: store, canvasSize: canvasSize)
            busy = false
            if let why { message = why; return }
            if design.startup {
                message = "Saved as DORM-E's resting screen."
            } else if design.seconds == 0 {
                message = "Showing on DORM-E until you change it."
            } else {
                let m = design.seconds / 60
                message = "Showing on DORM-E for \(m >= 60 ? "\(m / 60) hour" : "\(m) minute\(m == 1 ? "" : "s")")."
            }
        }
    }

    private func clear(startup: Bool) {
        Task {
            guard let client = store.client else { return }
            let ack = await client.send(.screenClear(startup: startup))
            if ack.ok && startup { design.forgetResting() }
            message = ack.ok ? "Back to the face." : ack.message
        }
    }
}

// MARK: - Pieces

/// The animated face with the chosen style and colour (the same drawing as the LCD).
private struct FacePreview: View {
    let style: String
    let color: RGB
    let date: Date
    @State private var animator = FaceAnimator()
    @State private var start = Date()

    var body: some View {
        let t = date.timeIntervalSince(start) + 6
        Image(uiImage: FaceRenderer.image(state: "idle", elapsed: t, stateElapsed: t, scale: 1, animator: animator,
                                          style: style, color: color.ui))
            .resizable()
            .aspectRatio(1.5, contentMode: .fit)
    }
}

/// Small still pictures of each style (cached per colour).
@MainActor
enum StyleThumb {
    private static var cache: [String: UIImage] = [:]
    static func image(_ style: String, _ color: RGB) -> UIImage {
        let key = "\(style)-\(color.r)-\(color.g)-\(color.b)"
        if let img = cache[key] { return img }
        let img = FaceRenderer.image(state: "idle", elapsed: 1, stateElapsed: 6, scale: 0.4, style: style, color: color.ui)
        cache[key] = img
        return img
    }
}

/// Eight swatches and one custom colour.
private struct SwatchRow: View {
    @Binding var selected: RGB
    @State private var custom = Color.white

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RGB.swatches, id: \.self) { c in
                Button { selected = c } label: {
                    Circle().fill(c.color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(selected == c ? Theme.ink : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Colour \(c.r) \(c.g) \(c.b)")
            }
            ColorPicker("Other colour", selection: Binding(get: { selected.color }, set: { selected = RGB($0) }),
                        supportsOpacity: false)
                .labelsHidden()
                .frame(maxWidth: .infinity)
        }
    }
}

private struct IconToggle: View {
    let symbol: String
    let on: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(on ? Theme.ink : Theme.cardRaised, in: Circle())
                .foregroundStyle(on ? Theme.background : Theme.ink)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The text layer on the preview, drawn the same way it is sent; drag it to move it.
private struct TextOverlay: View {
    let design: ScreenDesign
    let size: CGSize
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        if let img = design.textImage() {
            Image(uiImage: img)
                .resizable()
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onEnded { v in
                        let x = design.textCenter.x + v.translation.width / max(1, size.width)
                        let y = design.textCenter.y + v.translation.height / max(1, size.height)
                        design.textCenter = CGPoint(x: min(0.9, max(0.1, x)), y: min(0.9, max(0.1, y)))
                    })
                .accessibilityLabel("Text: \(design.text)")
        }
    }
}

/// PencilKit canvas without Apple's tool picker: the editor's own pen, eraser and colours drive it.
private struct CanvasView: UIViewRepresentable {
    let design: ScreenDesign
    let color: RGB
    let eraser: Bool
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(design) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.drawingPolicy = .anyInput                 // finger drawing (no Pencil needed)
        v.backgroundColor = .clear
        v.isOpaque = false
        v.overrideUserInterfaceStyle = .light       // ink colours exactly as picked (no dark-mode inversion)
        v.isScrollEnabled = false
        v.drawing = design.drawing
        v.delegate = context.coordinator
        v.accessibilityIdentifier = "screen.canvas"
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        v.tool = eraser ? PKEraserTool(.vector) : PKInkingTool(.pen, color: color.ui, width: 8)
        v.isUserInteractionEnabled = active
        if context.coordinator.revision != design.drawingRevision {
            context.coordinator.revision = design.drawingRevision
            v.drawing = design.drawing
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let design: ScreenDesign
        var revision: Int
        init(_ d: ScreenDesign) { design = d; revision = d.drawingRevision }
        nonisolated func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated {
                design.drawing = canvasView.drawing      // from the canvas itself: no revision bump, no reload
            }
        }
    }
}
