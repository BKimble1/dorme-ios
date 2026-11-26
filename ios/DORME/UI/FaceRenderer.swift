import UIKit

/// The robot's face, drawn the same way the Pi draws it on the LCD (port of dorme_robot/face/face.py,
/// `render_frame`, 480 x 320). Used as the texture of the 3D model's screen so the model shows what the robot shows.
///
/// `state` is the coordinator's `face.state`. The coordinator maps "moving" to the LCD's "listening" (face_adapter
/// FACE_MAP), so this does the same. The pairing code itself is never sent to the app; the pairing screen is drawn
/// with blank digit cells.
enum FaceRenderer {
    static let size = CGSize(width: 480, height: 320)
    private static let eye = UIColor(red: 205 / 255, green: 239 / 255, blue: 1, alpha: 1)
    private static let faultEye = UIColor(red: 1, green: 168 / 255, blue: 106 / 255, alpha: 1)
    private static let mouth = UIColor(red: 1, green: 140 / 255, blue: 58 / 255, alpha: 1)

    /// The LCD's own state names, after the coordinator's mapping.
    static func lcdState(_ coordinatorState: String?) -> String? {
        guard let s = coordinatorState else { return nil }
        switch s {
        case "moving": return "listening"
        case "idle", "listening", "happy", "puzzled", "low_energy", "sleepy", "fault", "pairing": return s
        default: return "idle"
        }
    }

    /// One frame. `elapsed`: seconds since the face started; `stateElapsed`: seconds in this state.
    /// `state == nil` is a dark screen (robot off or not connected).
    static func image(state: String?, elapsed: Double, stateElapsed: Double, scale: CGFloat = 2) -> UIImage {
        rgba8(size: size, scale: scale) { g in
            UIColor.black.setFill()
            g.fill(CGRect(origin: .zero, size: size))
            guard let state = lcdState(state) else { return }
            if state == "pairing" { drawPairing(g); return }
            draw(g, state: state, elapsed: elapsed, stateElapsed: stateElapsed)
        }
    }

    /// An 8-bit sRGB RGBA bitmap drawn with UIKit (top-left origin). SceneKit turns images into Metal textures;
    /// UIGraphicsImageRenderer's wide-colour/opaque formats can map to a pixel format Metal rejects (abort seen in
    /// the simulator run 2026-11-26), so textures are always made this way.
    static func rgba8(size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> UIImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return UIImage() }
        g.translateBy(x: 0, y: CGFloat(h))
        g.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(g)
        draw(g)
        UIGraphicsPopContext()
        guard let cg = g.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    private static func draw(_ g: CGContext, state: String, elapsed: Double, stateElapsed: Double) {
        if state == "sleepy" && stateElapsed > 1.5 { return }      // eyes closed, then a black last frame
        let blink = elapsed.truncatingRemainder(dividingBy: 4.7)
        var open = 1.0
        if blink < 0.22 && elapsed > 3 { open = max(0.06, abs(blink - 0.11) / 0.11) }
        switch state {
        case "sleepy": open = max(0.06, 1.0 - stateElapsed / 1.2) * 0.5
        case "low_energy": open *= 0.45
        case "happy": open *= 0.68
        default: break
        }
        let pulse = 1.0 + (state == "listening" ? 0.045 * sin(elapsed * 4) : 0)
        let lookX = state == "idle" ? Double(Int(6 * sin(elapsed / 2.7))) : 0
        let bob = Double(Int(2 * sin(elapsed * 1.2)))
        let color = state == "fault" ? faultEye : eye

        for (index, center) in [158.0, 322.0].enumerated() {
            let eh = Double(max(6, Int(110 * open * pulse)))
            let cy = 144 + bob + (state == "puzzled" && index == 1 ? 10 : 0)
            let ew = 92.0 + (state == "listening" ? 8 : 0)
            let box = CGRect(x: center + lookX - floor(ew / 2), y: cy - floor(eh / 2), width: ew, height: eh)
            color.setFill()
            UIBezierPath(roundedRect: box, cornerRadius: min(22, floor(eh / 2))).fill()
            if state == "happy" && eh > 20 {
                UIColor.black.setFill()
                UIBezierPath(ovalIn: CGRect(x: center + lookX - 52, y: cy + 4, width: 104, height: 80)).fill()
            }
        }
        if state == "puzzled" { line(g, [(120, 68), (185, 60)], color, 7) }
        if state == "fault" {
            line(g, [(300, 70), (350, 80)], color, 6)                                   // worried brow
            mouth.setFill()
            UIBezierPath(ovalIn: CGRect(x: 418, y: 40, width: 18, height: 18)).fill()   // small mark
        }
        switch state {
        case "happy":
            // PIL arc over the box (202, 191, 278, 249) from 5 to 175 degrees: the lower half of a 76 x 58 ellipse
            let p = UIBezierPath(arcCenter: .zero, radius: 1, startAngle: .pi * 5 / 180,
                                 endAngle: .pi * 175 / 180, clockwise: true)
            p.apply(CGAffineTransform(scaleX: 38, y: 29))
            p.apply(CGAffineTransform(translationX: 240, y: 220))
            p.lineWidth = 6
            mouth.setStroke()
            p.stroke()
        case "fault":
            line(g, [(218, 239), (240, 230), (262, 239)], mouth, 5)
        case "sleepy":
            break
        default:
            mouth.setFill()
            UIBezierPath(roundedRect: CGRect(x: 226, y: 235, width: 28, height: 5), cornerRadius: 2).fill()
        }
    }

    /// The pairing screen without the code: a QR-sized white panel and six empty blocky cells.
    private static func drawPairing(_ g: CGContext) {
        UIColor.white.setFill()
        g.fill(CGRect(x: 18, y: 35, width: 250, height: 250))
        UIColor.black.setFill()
        for i in 0..<3 { for j in 0..<3 where (i + j) % 2 == 0 {
            g.fill(CGRect(x: 38 + Double(i) * 75, y: 55 + Double(j) * 75, width: 60, height: 60))
        } }
        eye.withAlphaComponent(0.35).setFill()
        for k in 0..<6 {
            let x = 300 + Double(k % 3) * 60, y = 82 + Double(k / 3) * 92
            g.fill(CGRect(x: x, y: y, width: 48, height: 68))
        }
        let label = NSAttributedString(string: "PAIRING", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: mouth])
        label.draw(at: CGPoint(x: 345, y: 40))
    }

    private static func line(_ g: CGContext, _ pts: [(Double, Double)], _ color: UIColor, _ width: CGFloat) {
        let p = UIBezierPath()
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.lineWidth = width
        p.lineJoinStyle = .round
        color.setStroke()
        p.stroke()
    }
}
