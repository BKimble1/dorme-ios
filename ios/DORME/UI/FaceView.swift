import SwiftUI

/// The robot card's face: an original drawing in the spirit of the Pi's own face (pale-blue
/// rounded eyes, small orange mouth on a black panel). It mirrors `state.face.state`.
/// Drawn in the panel's 480 x 320 coordinate space and scaled to fit.
struct FaceView: View {
    var state: String
    var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || dimmed)) { context in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, t: context.date.timeIntervalSinceReferenceDate)
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement()
        .accessibilityLabel("Robot face")
        .accessibilityValue(FaceView.describe(state))
    }

    static func describe(_ s: String) -> String {
        switch s {
        case "happy": return "Happy"
        case "listening": return "Listening"
        case "moving": return "Looking where it is going"
        case "puzzled": return "Puzzled"
        case "low_energy": return "Low energy"
        case "sleepy": return "Going to sleep"
        case "pairing": return "Showing a pairing code"
        case "fault": return "Worried, a fault is active"
        default: return "Idle"
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, t: Double) {
        let sx = size.width / 480
        let sy = size.height / 320
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }

        var open = 1.0
        let blink = t.truncatingRemainder(dividingBy: 4.7)
        if blink < 0.22 && !reduceMotion { open = max(0.06, abs(blink - 0.11) / 0.11) }
        if state == "sleepy" { open = 0.07 }
        if state == "low_energy" { open *= 0.45 }
        if state == "happy" { open *= 0.68 }
        let wide = state == "listening" || state == "moving"
        let pulse = wide && !reduceMotion ? 1 + 0.045 * sin(t * 4) : 1
        let look = state == "idle" && !reduceMotion ? 6 * sin(t / 2.7) : 0
        let eyeColor = state == "fault" ? Color(red: 1, green: 0.66, blue: 0.42) : Theme.eye
        let mouthColor = Color(red: 1, green: 0.55, blue: 0.23)

        for (i, cx) in [158.0, 322.0].enumerated() {
            let eh = max(6, 110 * open * pulse)
            let ew = 92.0 + (wide ? 8 : 0)
            let cy = 144.0 + (state == "puzzled" && i == 1 ? 10 : 0)
            let rect = r(cx + look - ew / 2, cy - eh / 2, ew, eh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(22, eh / 2) * sx), with: .color(eyeColor))
            if state == "happy" && eh > 20 {
                ctx.fill(Path(ellipseIn: r(cx + look - 52, cy + 4, 104, 80)), with: .color(.black))
            }
        }
        if state == "happy" {
            var p = Path()
            p.addArc(center: pt(240, 204), radius: 34 * sx, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            ctx.stroke(p, with: .color(mouthColor), lineWidth: 6 * sx)
        } else if state == "fault" {
            var p = Path()
            p.move(to: pt(218, 239))
            p.addLine(to: pt(240, 230))
            p.addLine(to: pt(262, 239))
            ctx.stroke(p, with: .color(mouthColor), lineWidth: 5 * sx)
        } else if state != "sleepy" {
            ctx.fill(Path(roundedRect: r(226, 235, 28, 5), cornerRadius: 2 * sx), with: .color(mouthColor))
        }
        if state == "puzzled" {
            var p = Path()
            p.move(to: pt(120, 68))
            p.addLine(to: pt(185, 60))
            ctx.stroke(p, with: .color(eyeColor), lineWidth: 7 * sx)
        }
    }
}
