import SwiftUI

/// Warm white, black text, soft gray cards, large continuous corners.
enum Theme {
    static let background = Color(red: 0.980, green: 0.972, blue: 0.957)   // warm white
    static let card = Color(red: 0.941, green: 0.932, blue: 0.918)         // soft gray
    static let cardRaised = Color.white
    static let ink = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let inkSecondary = Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.58)
    static let inkTertiary = Color(red: 0.07, green: 0.07, blue: 0.07).opacity(0.38)
    static let hairline = Color.black.opacity(0.08)
    static let accent = Color(red: 0.93, green: 0.47, blue: 0.22)          // warm accent (selection)
    static let eye = Color(red: 0.843, green: 0.953, blue: 1.0)           // the face's eye colour (face rev 2)
    static let stop = Color(red: 0.84, green: 0.15, blue: 0.13)
    static let good = Color(red: 0.20, green: 0.58, blue: 0.34)
    static let warn = Color(red: 0.86, green: 0.55, blue: 0.10)
    static let bad = Color(red: 0.80, green: 0.20, blue: 0.16)

    static let radius: CGFloat = 28
    static let radiusSmall: CGFloat = 18
    static let gutter: CGFloat = 20
    static let spacing: CGFloat = 16
}

enum Level {
    case good, warn, bad, neutral, simulated
    var color: Color {
        switch self {
        case .good: return Theme.good
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        case .neutral: return Theme.inkTertiary
        case .simulated: return Theme.accent
        }
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    var fill: Color = Theme.card
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

struct CardHeader: View {
    var title: String
    var symbol: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.inkSecondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
    }
}

struct StatusDot: View {
    var level: Level
    var body: some View {
        Circle().fill(level.color).frame(width: 9, height: 9).accessibilityHidden(true)
    }
}

struct Pill: View {
    var text: String
    var symbol: String? = nil
    var level: Level = .neutral
    var filled = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
            else { StatusDot(level: level) }
            Text(text).font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(filled ? Color.white : Theme.ink)
        .background(filled ? AnyShapeStyle(level.color) : AnyShapeStyle(Color.white), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: filled ? 0 : 1))
        .accessibilityElement(children: .combine)
    }
}

/// The one Stop control. Large, red, always enabled: stop needs no pairing and works offline-first.
struct StopButton: View {
    var compact = false
    var action: () -> Void
    @State private var tick = 0

    var body: some View {
        Button {
            tick += 1
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "stop.fill").font(compact ? .headline : .title2.weight(.bold))
                Text("Stop").font(compact ? .headline : .title2.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 14 : 20)
            .foregroundStyle(.white)
            .background(Theme.stop, in: RoundedRectangle(cornerRadius: compact ? Theme.radiusSmall : Theme.radius, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .sensoryFeedback(.impact(weight: .heavy), trigger: tick)
        .accessibilityLabel("Stop robot")
        .accessibilityHint("Stops all movement and cancels the current task.")
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

struct ProgressCapsule: View {
    var value: Double?
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule().fill(Theme.ink)
                    .frame(width: max(8, geo.size.width * CGFloat(min(1, max(0, value ?? 0)))))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int($0 * 100)) percent" } ?? "Unknown")
    }
}

struct SectionTitle: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Grey out values that are stale or offline, and say so to VoiceOver.
    func staleness(_ dimmed: Bool) -> some View {
        self.opacity(dimmed ? 0.45 : 1)
            .saturation(dimmed ? 0 : 1)
            .accessibilityHint(dimmed ? "Out of date" : "")
    }
}
