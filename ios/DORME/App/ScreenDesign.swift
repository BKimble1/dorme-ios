import PencilKit
import SwiftUI
import DORMEKit

/// The owner's screen design (screen editor, 2026-11-26): a drawing and/or a line of text on black, 480 x 320 like the
/// LCD. The phone draws both layers itself (so the preview is exactly what DORM-E shows), uploads them as PNGs and
/// sends screen.show. The last design is kept on this phone so the editor reopens where it was.
@MainActor
@Observable
final class ScreenDesign {
    static let shared = ScreenDesign()
    static let pixels = CGSize(width: 480, height: 320)

    enum Font: String, CaseIterable, Identifiable {
        case clean, rounded, serif, mono, marker
        var id: String { rawValue }
        var name: String {
            switch self {
            case .clean: return "Clean"
            case .rounded: return "Round"
            case .serif: return "Serif"
            case .mono: return "Mono"
            case .marker: return "Marker"
            }
        }
        func uiFont(_ size: CGFloat) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            switch self {
            case .clean: return base
            case .rounded:
                return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            case .serif:
                let d = UIFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor.withDesign(.serif)
                return d.map { UIFont(descriptor: $0, size: size) } ?? base
            case .mono: return UIFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            case .marker: return UIFont(name: "MarkerFelt-Wide", size: size) ?? base
            }
        }
    }

    enum Blink: String, CaseIterable, Identifiable {
        case none, text, drawing, all
        var id: String { rawValue }
        var name: String {
            switch self {
            case .none: return "Off"
            case .text: return "Text"
            case .drawing: return "Drawing"
            case .all: return "Both"
            }
        }
    }

    var drawing = PKDrawing() { didSet { save() } }
    /// Bumped when the drawing changes from outside the canvas (undo, clear), so the canvas reloads it.
    private(set) var drawingRevision = 0

    func replaceDrawing(_ d: PKDrawing) {
        drawing = d
        drawingRevision += 1
    }
    var text = "" { didSet { save() } }
    var font: Font = .rounded { didSet { save() } }
    var textColor: RGB = RGB(255, 255, 255) { didSet { save() } }
    /// Text centre, as a fraction of the screen (drag it on the preview).
    var textCenter = CGPoint(x: 0.5, y: 0.5) { didSet { save() } }
    var blink: Blink = .none { didSet { save() } }
    var seconds = 0 { didSet { save() } }
    var startup = false { didSet { save() } }

    /// The frames last sent to the robot, so the app's 3D LCD shows them too.
    private(set) var shown: CustomScreenFrame?
    private(set) var resting: CustomScreenFrame?

    private let defaults = UserDefaults.standard
    private var loading = false

    init() {
        loading = true
        if let d = defaults.data(forKey: "screen.drawing"), let pk = try? PKDrawing(data: d) { drawing = pk }
        text = defaults.string(forKey: "screen.text") ?? ""
        font = Font(rawValue: defaults.string(forKey: "screen.font") ?? "") ?? .rounded
        if let c = defaults.array(forKey: "screen.textColor") as? [Int], c.count == 3 { textColor = RGB(c[0], c[1], c[2]) }
        if let p = defaults.array(forKey: "screen.textCenter") as? [Double], p.count == 2 { textCenter = CGPoint(x: p[0], y: p[1]) }
        blink = Blink(rawValue: defaults.string(forKey: "screen.blink") ?? "") ?? .none
        seconds = defaults.object(forKey: "screen.seconds") as? Int ?? 600
        startup = defaults.bool(forKey: "screen.startup")
        resting = Self.loadFrame("resting")
        shown = Self.loadFrame("shown")
        loading = false
    }

    private func save() {
        guard !loading else { return }
        defaults.set(drawing.dataRepresentation(), forKey: "screen.drawing")
        defaults.set(text, forKey: "screen.text")
        defaults.set(font.rawValue, forKey: "screen.font")
        defaults.set([textColor.r, textColor.g, textColor.b], forKey: "screen.textColor")
        defaults.set([Double(textCenter.x), Double(textCenter.y)], forKey: "screen.textCenter")
        defaults.set(blink.rawValue, forKey: "screen.blink")
        defaults.set(seconds, forKey: "screen.seconds")
        defaults.set(startup, forKey: "screen.startup")
    }

    var isEmpty: Bool { drawing.strokes.isEmpty && text.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Rendering (exactly 480 x 320 pixels, transparent where nothing is drawn)

    /// The drawing, from the canvas (whose bounds are `canvasSize` points) scaled to the LCD.
    func drawingImage(canvasSize: CGSize) -> UIImage? {
        guard !drawing.strokes.isEmpty, canvasSize.width > 0 else { return nil }
        let scale = Self.pixels.width / canvasSize.width
        var img: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = drawing.image(from: CGRect(origin: .zero, size: canvasSize), scale: 2 * scale)
        }
        guard let img else { return nil }
        return FaceRenderer.rgba8(size: Self.pixels, scale: 1) { _ in
            img.draw(in: CGRect(origin: .zero, size: Self.pixels))
        }
    }

    /// Auto-fitted text (the largest size that fits, wrapped on words), centred on `textCenter`.
    func textImage() -> UIImage? {
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        let (f, rect) = textLayout(t)
        return FaceRenderer.rgba8(size: Self.pixels, scale: 1) { _ in
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            (t as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                 attributes: [.font: f, .foregroundColor: textColor.ui, .paragraphStyle: style], context: nil)
        }
    }

    func textLayout(_ t: String) -> (UIFont, CGRect) {
        let maxW: CGFloat = 440, maxH: CGFloat = 280
        var chosen = font.uiFont(20)
        var size = CGSize(width: maxW, height: 40)
        for s in [120, 104, 92, 80, 70, 60, 52, 44, 38, 32, 28, 24, 20] as [CGFloat] {
            let f = font.uiFont(s)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let r = (t as NSString).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin],
                                                 attributes: [.font: f, .paragraphStyle: style], context: nil)
            let longest = t.split(separator: " ").map { ($0 as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0
            if r.height <= maxH && longest <= maxW {
                chosen = f
                size = CGSize(width: maxW, height: ceil(r.height))
                break
            }
        }
        let cx = textCenter.x * Self.pixels.width, cy = textCenter.y * Self.pixels.height
        var y = cy - size.height / 2
        y = min(max(4, y), Self.pixels.height - 4 - size.height)
        let x = min(max(20, cx - maxW / 2), Self.pixels.width - 20 - maxW)
        return (chosen, CGRect(x: x, y: y, width: maxW, height: size.height))
    }

    /// What the robot will show, for the preview and the app's 3D LCD.
    func frame(canvasSize: CGSize) -> CustomScreenFrame {
        var layers: [(UIImage, Bool)] = []
        if let d = drawingImage(canvasSize: canvasSize) { layers.append((d, blink == .drawing || blink == .all)) }
        if let t = textImage() { layers.append((t, blink == .text || blink == .all)) }
        return CustomScreenFrame(background: .black, layers: layers.map { (image: $0.0, blink: $0.1) })
    }

    // MARK: Sending

    /// Uploads the layers and shows them. nil = done; else what went wrong.
    func send(store: RobotStore, canvasSize: CGSize) async -> String? {
        guard let client = store.client else { return "Not connected to DORM-E." }
        let frame = frame(canvasSize: canvasSize)
        guard !frame.layers.isEmpty else { return "Draw something or type some text first." }
        var layers: [JSONValue] = []
        for layer in frame.layers {
            guard let png = layer.image.pngData() else { return "Could not make the picture." }
            let ack = await client.uploadScreenImage(png)
            guard ack.ok, let file = ack.result.lookup("file")?.string else { return ack.message }
            layers.append(.object(["kind": .string("image"), "file": .string(file), "blink": .bool(layer.blink)]))
        }
        let t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = t.isEmpty ? "Your drawing" : String(t.prefix(40))
        let ack = await client.send(.screenShow(layers: layers, seconds: startup ? 0 : seconds, startup: startup, label: label))
        guard ack.ok else { return ack.message }
        if startup {
            resting = frame
            Self.saveFrame(frame, "resting")
        } else {
            shown = frame
            Self.saveFrame(frame, "shown")
        }
        return nil
    }

    func forgetResting() {
        resting = nil
        Self.saveFrame(nil, "resting")
    }

    // MARK: Frames on disk (Application Support/screen/<name>-<i>.png + .json)

    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("screen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func saveFrame(_ frame: CustomScreenFrame?, _ name: String) {
        let fm = FileManager.default
        for i in 0..<4 { try? fm.removeItem(at: folder.appendingPathComponent("\(name)-\(i).png")) }
        guard let frame else {
            try? fm.removeItem(at: folder.appendingPathComponent("\(name).json"))
            return
        }
        var blinks: [Bool] = []
        for (i, layer) in frame.layers.enumerated() {
            try? layer.image.pngData()?.write(to: folder.appendingPathComponent("\(name)-\(i).png"))
            blinks.append(layer.blink)
        }
        try? JSONSerialization.data(withJSONObject: ["blink": blinks]).write(to: folder.appendingPathComponent("\(name).json"))
    }

    private static func loadFrame(_ name: String) -> CustomScreenFrame? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blinks = obj["blink"] as? [Bool] else { return nil }
        var layers: [(image: UIImage, blink: Bool)] = []
        for (i, b) in blinks.enumerated() {
            guard let img = UIImage(contentsOfFile: folder.appendingPathComponent("\(name)-\(i).png").path) else { return nil }
            layers.append((img, b))
        }
        return layers.isEmpty ? nil : CustomScreenFrame(background: .black, layers: layers)
    }
}

/// An sRGB colour as the robot takes it ([r, g, b], 0-255).
struct RGB: Equatable, Hashable {
    var r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    init(_ c: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Int((max(0, min(1, r)) * 255).rounded()), Int((max(0, min(1, g)) * 255).rounded()),
                  Int((max(0, min(1, b)) * 255).rounded()))
    }
    init?(_ list: [Int]?) {
        guard let l = list, l.count == 3 else { return nil }
        self.init(l[0], l[1], l[2])
    }
    var ui: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var color: Color { Color(ui) }
    var list: [Int] { [r, g, b] }

    /// Swatches: the eyes' default ice blue first, then a short spread that reads well on black.
    static let swatches: [RGB] = [RGB(215, 243, 255), RGB(255, 255, 255), RGB(255, 214, 10), RGB(255, 149, 0),
                                  RGB(255, 69, 58), RGB(255, 120, 190), RGB(175, 130, 255), RGB(48, 209, 88)]
}

/// How the app's 3D LCD should look: the robot's saved face style and colour, the amber "look at the app" dot, and
/// the owner's screen when one is showing (drawn from the frames this phone sent).
struct LCDLook: Equatable {
    var style: String?
    var color: UIColor?
    var alert = false
    var custom: CustomScreenFrame?
    var restingCustom = false
}

extension RobotStore {
    var lcdLook: LCDLook {
        let sc = state?.screen
        let code = state?.fault.active?.code
        let design = ScreenDesign.shared
        let custom: CustomScreenFrame? = sc?.custom != nil ? design.shown : (sc?.resting != nil ? design.resting : nil)
        return LCDLook(style: sc?.face?.style, color: RGB(sc?.face?.color)?.ui,
                       alert: code != nil && code != "SONAR_FAIL" && code != "LOW_BUS",
                       custom: custom, restingCustom: sc?.resting != nil && design.resting != nil)
    }
}
