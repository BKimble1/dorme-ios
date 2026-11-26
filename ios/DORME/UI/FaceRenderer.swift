import DORMEKit
import UIKit

/// The robot's face, drawn the way the Pi draws it on the LCD (port of dorme_robot/face/face.py rev 2, 480 x 320).
/// Used as the texture of the 3D model's screen, so the model shows what the robot shows.
///
/// Rev 2 (2026-11-26): eyes only. Two soft "squircle" eyes on black, one colour, no mouth. Every look is a set of
/// eye parameters; `FaceAnimator` eases between them, blinks at irregular intervals (Vector's blink curve) and
/// glances around when idle. The eye outline is built exactly as in face.py (`eye_outline`), so the shapes match.
/// The pairing code itself is never sent to the app; the pairing screen is drawn without digits.
enum FaceRenderer {
    static let size = CGSize(width: 480, height: 320)
    static let eyeColor = UIColor(red: 215 / 255, green: 243 / 255, blue: 1, alpha: 1)
    private static let amber = (r: 255.0, g: 178.0, b: 92.0)
    private static let text = UIColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
    private static let textDim = UIColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
    private static let eyeGap = 112.0, eyeY = 152.0, squircleN = 3.6, hotspot = 0.06

    /// The LCD's own state names (the coordinator's names pass through since face rev 2).
    static func lcdState(_ coordinatorState: String?) -> String? {
        guard let s = coordinatorState else { return nil }
        switch s {
        case "idle", "listening", "moving", "happy", "puzzled", "low_energy", "sleepy", "fault", "pairing", "note",
             "ack", "waking", "navigating": return s
        default: return "idle"
        }
    }

    // MARK: Eye parameters (face.py NEUTRAL / EXPRESSIONS)

    struct Eye {
        var w = 108.0, h = 150.0, lid = 0.0, tilt = 0.0, low = 0.0, smile = 0.0, dx = 0.0, dy = 0.0, s = 1.0, b = 1.0, warm = 0.0

        mutating func approach(_ t: Eye, _ k: Double) {
            w += (t.w - w) * k; h += (t.h - h) * k; lid += (t.lid - lid) * k; tilt += (t.tilt - tilt) * k
            low += (t.low - low) * k; smile += (t.smile - smile) * k; dx += (t.dx - dx) * k; dy += (t.dy - dy) * k
            s += (t.s - s) * k; b += (t.b - b) * k; warm += (t.warm - warm) * k
        }
    }

    private static func pair(_ e: Eye) -> (Eye, Eye) { (e, e) }

    private static let expressions: [String: (Eye, Eye)] = [
        "idle": pair(Eye()),
        "waking": pair(Eye()),
        "ack": pair(Eye()),
        "listening": pair(Eye(h: 158, dy: -6, s: 1.04)),
        "moving": pair(Eye(lid: 0.14, tilt: 4)),
        "navigating": pair(Eye(lid: 0.26, tilt: 6, low: 0.10)),
        "happy": pair(Eye(smile: 0.48, dy: -8, s: 1.04)),
        "puzzled": (Eye(low: 0.12, dy: -4, s: 1.04), Eye(lid: 0.30, tilt: 10, low: 0.16, dy: 4, s: 0.92)),
        "low_energy": pair(Eye(lid: 0.40, tilt: -5, low: 0.14, dy: 12, b: 0.62)),
        "fault": pair(Eye(lid: 0.18, tilt: -15, dy: 4, s: 0.94, warm: 1)),
        "sleepy": pair(Eye(lid: 0.50, low: 0.10, dy: 14, b: 0.8)),
    ]
    private static let gazeByDir: [String: (Double, Double)] = ["L": (-52, 0), "R": (52, 0), "F": (0, -6), "B": (0, 14)]

    struct Flags { var blink = true, saccade = false, slowBlink = false }

    private static func easeInOut(_ x: Double) -> Double { let x = min(1, max(0, x)); return x * x * (3 - 2 * x) }
    private static func easeOut(_ x: Double) -> Double { let x = min(1, max(0, x)); return 1 - pow(1 - x, 3) }
    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// face.py `expression`: target eyes for a state, before gaze and blinks.
    static func expression(_ state: String, _ t: Double, _ direction: String?) -> (Eye, Eye, (Double, Double), Flags) {
        var (l, r) = expressions[state] ?? expressions["idle"]!
        var gaze = (0.0, 0.0)
        var flags = Flags(blink: true, saccade: state == "idle" || state == "listening",
                          slowBlink: state == "low_energy" || state == "sleepy")
        switch state {
        case "waking":
            let f: Double
            if t < 0.25 { f = mix(0.05, 0.32, easeOut(t / 0.25)) }
            else if t < 0.55 { f = 0.32 }
            else if t < 0.66 { f = mix(0.32, 0.05, (t - 0.55) / 0.11) }
            else if t < 0.95 { f = mix(0.05, 1.06, easeOut((t - 0.66) / 0.29)) }
            else { f = mix(1.06, 1.0, easeInOut((t - 0.95) / 0.2)) }
            l.h *= f; r.h *= f
            l.b = mix(0.6, 1, easeInOut(t / 0.9)); r.b = l.b
            gaze = (t > 1.25 && t < 1.65) ? (-30, -4) : (t > 1.65 && t < 2.05) ? (30, -4) : (0, 0)
            flags.blink = t > 2.4
            flags.saccade = false
        case "sleepy":
            let lid = min(1, 0.55 + 0.45 * easeInOut(t / 1.2))
            l.lid = lid; r.lid = lid
            flags.blink = false
        case "ack":
            let nod = 10 * sin(Double.pi * min(1, t / 0.45))
            l.dy += nod; r.dy += nod
        case "happy":
            let bounce = 5 * sin(t * 2 * .pi * 1.6) * exp(-t * 1.8)
            l.dy -= bounce; r.dy -= bounce
        case "puzzled":
            gaze = (34, -22)
            flags.saccade = false
        case "moving":
            gaze = direction.flatMap { gazeByDir[$0] } ?? (0, -4)
        case "navigating":
            gaze = (0, -6)
        default: break
        }
        return (l, r, gaze, flags)
    }

    // MARK: Outline (face.py eye_outline, _resample, _smooth)

    private static func geometry(_ e: Eye, _ side: Double, _ gaze: (Double, Double), _ open: Double)
        -> (cx: Double, cy: Double, w: Double, h: Double) {
        let turn = max(-1, min(1, gaze.0 / 50))
        let s = e.s * (1 + 0.06 * turn * side)
        let w = e.w * s * (1 + 0.18 * (1 - open))
        let h = max(5, e.h * s * open)
        let cx = 240 + side * eyeGap * (1 - 0.05 * abs(turn)) + e.dx + gaze.0
        let cy = eyeY + e.dy + gaze.1
        return (cx, cy, w, h)
    }

    static func outline(_ e: Eye, side: Double, gaze: (Double, Double), open: Double) -> [CGPoint] {
        let g = geometry(e, side, gaze, open)
        let a = g.w / 2, b = g.h / 2
        let lids = open >= 0.25 && (e.lid > 0.005 || e.low > 0.005 || e.smile > 0.005 || abs(e.tilt) > 0.3)
        let slope = tan(e.tilt * .pi / 180) * -side
        let n = 56
        var tops: [CGPoint] = [], bots: [CGPoint] = []
        for i in 0..<n {
            let x = g.cx + a * sin(-Double.pi / 2 + Double.pi * Double(i) / Double(n - 1))
            let u = min(1, abs(x - g.cx) / a)
            let sq = b * pow(1 - pow(u, squircleN), 1 / squircleN)
            var top = g.cy - sq, bot = g.cy + sq
            if lids {
                top = max(top, g.cy - b + e.lid * g.h + slope * (x - g.cx))
                bot = min(bot, g.cy + b - e.low * g.h)
                if e.smile > 0.005 {
                    let rx = g.w * 0.98, ry = g.h * 0.72
                    let ccy = g.cy + b - e.smile * g.h + ry
                    let d = (x - g.cx) / rx
                    if abs(d) < 1 { bot = min(bot, ccy - ry * (1 - d * d).squareRoot()) }
                }
            }
            if bot - top > 0.3 {
                tops.append(CGPoint(x: x, y: top))
                bots.append(CGPoint(x: x, y: bot))
            }
        }
        guard tops.count >= 2 else { return [] }
        let poly = tops + bots.reversed()
        return lids ? smooth(resample(poly, 2), half: 2, passes: 3) : poly
    }

    private static func resample(_ p: [CGPoint], _ step: Double) -> [CGPoint] {
        var out: [CGPoint] = [], carry = 0.0
        for i in 0..<p.count {
            let p0 = p[i], p1 = p[(i + 1) % p.count]
            let seg = hypot(p1.x - p0.x, p1.y - p0.y)
            var d = carry
            while d < seg {
                let t = d / seg
                out.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
                d += step
            }
            carry = d - seg
        }
        return out.isEmpty ? p : out
    }

    private static func smooth(_ p: [CGPoint], half: Int, passes: Int) -> [CGPoint] {
        var pts = p
        let m = pts.count
        guard m >= 2 * half + 2 else { return pts }
        for _ in 0..<passes {
            pts = (0..<m).map { i in
                var x = 0.0, y = 0.0
                for k in -half...half { let q = pts[(i + k + m) % m]; x += q.x; y += q.y }
                let c = Double(2 * half + 1)
                return CGPoint(x: x / c, y: y / c)
            }
        }
        return pts
    }

    // MARK: Frames

    /// One frame. `elapsed`: seconds since the face started; `stateElapsed`: seconds in this state.
    /// `state == nil` is a dark screen (robot off or not connected). With an animator the look eases between frames.
    static func image(state: String?, elapsed: Double, stateElapsed: Double, scale: CGFloat = 2,
                      note: ScreenNote? = nil, direction: String? = nil, animator: FaceAnimator? = nil) -> UIImage {
        rgba8(size: size, scale: scale) { g in
            UIColor.black.setFill()
            g.fill(CGRect(origin: .zero, size: size))
            guard var state = lcdState(state) else { return }
            if state == "pairing" { drawPairing(g); return }
            if state == "note" {
                if let note, !note.text.isEmpty { drawNote(g, note, elapsed: elapsed); return }
                state = "idle"
            }
            if state == "sleepy" && stateElapsed > 1.5 { return }
            let l: Eye, r: Eye, gaze: (Double, Double), open: Double
            if let animator {
                (l, r, gaze, open) = animator.step(elapsed, state, stateElapsed, direction)
            } else {
                let x = expression(state, stateElapsed, direction)
                (l, r, gaze) = (x.0, x.1, x.2)
                let b = elapsed.truncatingRemainder(dividingBy: 4.7)
                open = (b < 0.22 && elapsed > 3 && state != "sleepy" && state != "waking") ? max(0.05, abs(b - 0.11) / 0.11) : 1
            }
            drawEyes(g, l, r, gaze, open)
        }
    }

    private static func color(_ warm: Double, _ b: Double) -> (UIColor, UIColor) {
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        eyeColor.getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        let rr = mix(Double(r0) * 255, amber.r, warm) / 255, gg = mix(Double(g0) * 255, amber.g, warm) / 255
        let bb = mix(Double(b0) * 255, amber.b, warm) / 255
        let base = UIColor(red: rr * b * (1 - hotspot), green: gg * b * (1 - hotspot), blue: bb * b * (1 - hotspot), alpha: 1)
        let hot = UIColor(red: min(1, rr * b * 1.07), green: min(1, gg * b * 1.07), blue: min(1, bb * b * 1.07), alpha: 1)
        return (base, hot)
    }

    private static func drawEyes(_ g: CGContext, _ l: Eye, _ r: Eye, _ gaze: (Double, Double), _ open: Double) {
        let (base, hot) = color((l.warm + r.warm) / 2, 1)
        for (e, side) in [(l, -1.0), (r, 1.0)] where e.b > 0.01 {
            let pts = outline(e, side: side, gaze: gaze, open: open)
            guard pts.count >= 3 else { continue }
            let path = UIBezierPath()
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            let geo = geometry(e, side, gaze, open)
            g.saveGState()
            g.setAlpha(CGFloat(e.b))
            path.addClip()
            base.setFill()
            g.fill(path.bounds)
            // the soft highlight, 0.48 eye widths across, follows the gaze
            let c = CGPoint(x: geo.cx + 0.5 * gaze.0, y: geo.cy - 0.12 * geo.h + 0.5 * gaze.1)
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [hot.cgColor, base.cgColor] as CFArray, locations: [0, 1]) {
                g.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: 0.48 * geo.w * 1.4,
                                     options: [])
            }
            g.restoreGState()
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

    // MARK: Text screens (face.py render_note / render_pairing)

    private static func miniEyes(_ g: CGContext, y: Double, elapsed: Double) {
        let b = elapsed.truncatingRemainder(dividingBy: 4.7)
        let open = (b < 0.22 && elapsed > 3) ? max(0.05, abs(b - 0.11) / 0.11) : 1
        eyeColor.setFill()
        for cx in [214.0, 266.0] {
            let h = max(4, 38 * open)
            let p = UIBezierPath()
            for i in 0..<48 {
                let th = 2 * Double.pi * Double(i) / 48
                let c = cos(th), s = sin(th)
                let pt = CGPoint(x: cx + 15 * copysign(pow(abs(c), 2 / squircleN), c),
                                 y: y + h / 2 * copysign(pow(abs(s), 2 / squircleN), s))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            p.close()
            p.fill()
        }
    }

    private static func drawNote(_ g: CGContext, _ note: ScreenNote, elapsed: Double) {
        miniEyes(g, y: 44, elapsed: elapsed)
        let remaining = note.until.map { max(0, Int(($0 - Date().timeIntervalSince1970).rounded())) }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineHeightMultiple = 1.05
        let (top, bottom): (CGFloat, CGFloat) = remaining == nil ? (84, 296) : (80, 170)
        let maxLines = remaining == nil ? 3 : 2
        var attrs: [NSAttributedString.Key: Any] = [:]
        var h: CGFloat = 0
        for size in [38.0, 34, 30, 27, 24, 22] {
            attrs = [.font: UIFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: text, .paragraphStyle: para]
            h = NSAttributedString(string: note.text, attributes: attrs)
                .boundingRect(with: CGSize(width: 432, height: 1000), options: [.usesLineFragmentOrigin], context: nil).height
            if h <= size * 1.3 * CGFloat(maxLines) { break }
        }
        h = min(h, bottom - top)
        NSAttributedString(string: note.text, attributes: attrs)
            .draw(with: CGRect(x: 24, y: top + (bottom - top - h) / 2, width: 432, height: h),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        if let r = remaining {
            let clock = r >= 3600 ? String(format: "%d:%02d:%02d", r / 3600, r % 3600 / 60, r % 60)
                                  : String(format: "%02d:%02d", r / 60, r % 60)
            let level = r > 0 ? 1.0 : 0.45 + 0.55 * (0.5 + 0.5 * cos(elapsed * .pi * 1.6))
            let big: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: r >= 3600 ? 84 : 104, weight: .medium),
                .foregroundColor: eyeColor.withAlphaComponent(CGFloat(level)), .paragraphStyle: para]
            NSAttributedString(string: clock, attributes: big).draw(in: CGRect(x: 0, y: r >= 3600 ? 184 : 170, width: 480, height: 130))
        }
    }

    /// The pairing screen without the code (the code never leaves the robot): the label and six quiet dots.
    private static func drawPairing(_ g: CGContext) {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        NSAttributedString(string: "Pairing code", attributes: [
            .font: UIFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: textDim, .paragraphStyle: para])
            .draw(in: CGRect(x: 0, y: 70, width: 480, height: 30))
        eyeColor.withAlphaComponent(0.4).setFill()
        for k in 0..<6 {
            let x = 240 - 150 + Double(k) * 52 + (k >= 3 ? 24 : 0)
            UIBezierPath(ovalIn: CGRect(x: x, y: 152, width: 16, height: 16)).fill()
        }
        NSAttributedString(string: "Shown on DORM-E's screen", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .regular), .foregroundColor: textDim, .paragraphStyle: para])
            .draw(in: CGRect(x: 0, y: 236, width: 480, height: 30))
    }
}

/// face.py `Animator`: eases between looks, blinks with Vector's curve at irregular intervals, glances when idle.
final class FaceAnimator {
    private var cur: (FaceRenderer.Eye, FaceRenderer.Eye)?
    private var lastT: Double?
    private var gaze = (0.0, 0.0), gazeTarget = (0.0, 0.0)
    private var nextSaccade = 1.5, nextBlink = 2.5
    private var blinkStart: Double?, blinkSecond = false
    private var seen: String?
    private var rng = SystemRandomNumberGenerator()
    private static let blink: [(Double, Double)] = [(0, 1), (0.033, 0.85), (0.066, 0.6), (0.099, 0.1), (0.132, 0.05),
                                                    (0.165, 0.15), (0.198, 0.7), (0.231, 0.9), (0.331, 1)]

    private func uniform(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }

    private func blinkCurve(_ t: Double, slow: Bool) -> Double {
        guard let start = blinkStart else { return 1 }
        let x = (t - start) / (slow ? 1.8 : 1)
        if x >= Self.blink.last!.0 {
            if blinkSecond { blinkSecond = false; blinkStart = t + 0.12; return 1 }
            blinkStart = nil
            return 1
        }
        if x < 0 { return 1 }
        for i in 0..<(Self.blink.count - 1) where Self.blink[i].0 <= x && x < Self.blink[i + 1].0 {
            let (t0, v0) = Self.blink[i], (t1, v1) = Self.blink[i + 1]
            return v0 + (v1 - v0) * (x - t0) / (t1 - t0)
        }
        return 1
    }

    func step(_ t: Double, _ state: String, _ stateElapsed: Double, _ direction: String?)
        -> (FaceRenderer.Eye, FaceRenderer.Eye, (Double, Double), Double) {
        let (l, r, gazeGoal, flags) = FaceRenderer.expression(state, stateElapsed, direction)
        let dt = lastT.map { max(0, min(0.25, t - $0)) } ?? 0.066
        lastT = t
        if cur == nil { cur = (l, r) }
        let k = 1 - exp(-dt / 0.075)
        cur!.0.approach(l, k)
        cur!.1.approach(r, k)
        let target: (Double, Double)
        if flags.saccade {
            if t >= nextSaccade {
                let amp = state == "listening" ? 0.6 : 1.0
                gazeTarget = uniform(0, 1) < 0.45 ? (0, 0) : (uniform(-40, 40) * amp, uniform(-18, 12) * amp)
                nextSaccade = t + uniform(1.0, 2.25) * (uniform(0, 1) < 0.7 ? 1 : 2)
            }
            target = gazeTarget
        } else {
            target = gazeGoal
            nextSaccade = t + uniform(0.8, 2.0)
        }
        let kg = 1 - exp(-dt / 0.045)
        let jump = hypot(target.0 - gaze.0, target.1 - gaze.1)
        gaze.0 += (target.0 - gaze.0) * kg
        gaze.1 += (target.1 - gaze.1) * kg
        let dart = jump > 12 ? 0.85 : 1.0
        var open = 1.0
        if blinkStart != nil {
            open = blinkCurve(t, slow: flags.slowBlink)
        } else if flags.blink && t >= nextBlink {
            blinkStart = t
            blinkSecond = uniform(0, 1) < 0.12
            let gap = 2.6 + min(7.4, -log(max(1e-6, uniform(0, 1))) * 1.9)
            nextBlink = t + gap * (flags.slowBlink ? 1.6 : 1)
        }
        if state != seen && (state == "ack" || state == "happy") { blinkStart = t; blinkSecond = false }
        seen = state
        let breathe = 1 + 0.010 * sin(t * 2 * .pi / 4.6)
        var a = cur!.0, b = cur!.1
        a.h *= breathe; b.h *= breathe
        return (a, b, gaze, open * dart)
    }
}
